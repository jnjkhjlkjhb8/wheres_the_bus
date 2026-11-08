package main

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"github.com/robfig/cron/v3"
	"go.uber.org/zap"
)

// TDX bills the higher of two meters: 1 point per 1,500 calls, or 1 point per
// 150 MB.
const (
	_tdxCallsPerPoint = 1500
	_tdxBytesPerMB    = 1024 * 1024
	_tdxMBPerPoint    = 150
)

const (
	_tdxDefaultPointAlert = 15
	_tdxUsageTopNames     = 5
	_tdxUsageJobTimeout   = 30 * time.Second
	_tdxAlertPostTimeout  = 10 * time.Second
	// The flag must outlive the rest of its Taipei day from any time of day.
	_tdxAlertFlagTTL = 48 * time.Hour
)

func registerTDXUsageCrons(r *cron.Cron, rc redis.Cmdable) {
	_, _ = addStaticCron(r, "@every 5m", func() { checkTDXUsage(rc, time.Now()) })
	_, _ = addStaticCron(r, "0 45 4 * * *", func() { logTDXUsage(rc, time.Now()) })
}

func tdxPoints(calls, size int64) float64 {
	return max(float64(calls)/_tdxCallsPerPoint, tdxMB(size)/_tdxMBPerPoint)
}

func tdxMB(size int64) float64 { return float64(size) / _tdxBytesPerMB }

// tdxPointAlertThreshold falls back to the default for an unset or malformed
// value, so a typo cannot silently switch the alert off.
func tdxPointAlertThreshold(raw string) float64 {
	threshold, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil {
		return _tdxDefaultPointAlert
	}
	return threshold
}

type tdxNameUsage struct {
	name        string
	calls       int64
	notModified int64
	bytes       int64
}

func (u tdxNameUsage) points() float64 { return tdxPoints(u.calls, u.bytes) }

func (u *tdxNameUsage) add(kind string, value int64) {
	switch kind {
	case shared.TDXUsageCalls:
		u.calls += value
	case shared.TDXUsageNotModified:
		u.notModified += value
	case shared.TDXUsageBytes:
		u.bytes += value
	}
}

type tdxUsageReport struct {
	total tdxNameUsage
	// names is sorted by bytes, largest first.
	names []tdxNameUsage
}

func parseTDXUsage(fields map[string]string) tdxUsageReport {
	byName := make(map[string]*tdxNameUsage)
	for field, raw := range fields {
		kind, name, _ := strings.Cut(field, ":")
		value, _ := strconv.ParseInt(raw, 10, 64)
		tdxUsageEntry(byName, name).add(kind, value)
	}
	return newTDXUsageReport(byName)
}

func tdxUsageEntry(byName map[string]*tdxNameUsage, name string) *tdxNameUsage {
	entry, ok := byName[name]
	if !ok {
		entry = &tdxNameUsage{name: name}
		byName[name] = entry
	}
	return entry
}

func newTDXUsageReport(byName map[string]*tdxNameUsage) tdxUsageReport {
	report := tdxUsageReport{total: tdxNameUsage{name: shared.TDXUsageTotal}}
	for name, usage := range byName {
		if name == shared.TDXUsageTotal {
			report.total = *usage
			continue
		}
		report.names = append(report.names, *usage)
	}
	slices.SortFunc(report.names, func(a, b tdxNameUsage) int {
		return cmp.Or(cmp.Compare(b.bytes, a.bytes), strings.Compare(a.name, b.name))
	})
	return report
}

func readTDXUsage(ctx context.Context, rc redis.Cmdable, day string) (tdxUsageReport, error) {
	fields, err := rc.HGetAll(ctx, shared.TDXUsageKey(day)).Result()
	if err != nil {
		return tdxUsageReport{}, _oops.With("day", day).Wrapf(err, "read TDX usage")
	}
	return parseTDXUsage(fields), nil
}

func readTDXUsageTotal(ctx context.Context, rc redis.Cmdable, day string) (tdxNameUsage, error) {
	values, err := rc.HMGet(ctx, shared.TDXUsageKey(day),
		shared.TDXUsageField(shared.TDXUsageCalls, shared.TDXUsageTotal),
		shared.TDXUsageField(shared.TDXUsageBytes, shared.TDXUsageTotal),
	).Result()
	if err != nil {
		return tdxNameUsage{}, _oops.With("day", day).Wrapf(err, "read TDX usage totals")
	}
	return tdxNameUsage{name: shared.TDXUsageTotal, calls: tdxHashInt(values[0]), bytes: tdxHashInt(values[1])}, nil
}

// tdxHashInt reads one HMGET value; a missing field is nil and counts as 0.
func tdxHashInt(value any) int64 {
	text, _ := value.(string)
	n, _ := strconv.ParseInt(text, 10, 64)
	return n
}

func tdxUsageAlertedKey(day string) string { return shared.TDXUsageKey(day) + ":alerted" }

type tdxUsageAlert struct {
	rc        redis.Cmdable
	client    *http.Client
	webhook   string
	threshold float64
}

func checkTDXUsage(rc redis.Cmdable, now time.Time) {
	ctx, cancel := context.WithTimeout(context.Background(), _tdxUsageJobTimeout)
	defer cancel()
	alert := tdxUsageAlert{
		rc:        rc,
		client:    &http.Client{Timeout: _tdxAlertPostTimeout},
		webhook:   os.Getenv("ALERT_WEBHOOK_URL"),
		threshold: tdxPointAlertThreshold(os.Getenv("TDX_DAILY_POINT_ALERT")),
	}
	if err := alert.run(ctx, shared.TDXUsageDay(now)); err != nil {
		zap.S().Warnw("check failed", "component", "tdx", "action", "usage_alert", "event", "check_failed", "err", err)
	}
}

func (a tdxUsageAlert) run(ctx context.Context, day string) error {
	if a.threshold <= 0 {
		return nil
	}
	total, err := readTDXUsageTotal(ctx, a.rc, day)
	if err != nil {
		return err
	}
	if total.points() >= a.threshold {
		return a.alertOnce(ctx, day)
	}
	return nil
}

func (a tdxUsageAlert) alertOnce(ctx context.Context, day string) error {
	flag := tdxUsageAlertedKey(day)
	first, err := a.rc.SetNX(ctx, flag, "1", _tdxAlertFlagTTL).Result()
	if err != nil {
		return _oops.With("day", day).Wrapf(err, "claim TDX usage alert")
	}
	if !first {
		return nil
	}
	if err := a.notify(ctx, day); err != nil {
		// Releasing the flag lets the next run try again.
		return errors.Join(err, a.rc.Del(ctx, flag).Err())
	}
	return nil
}

func (a tdxUsageAlert) notify(ctx context.Context, day string) error {
	report, err := readTDXUsage(ctx, a.rc, day)
	if err != nil {
		return err
	}
	content := tdxUsageAlertContent(day, report, a.threshold)
	zap.S().Warnw("daily points over threshold", "component", "tdx", "action", "usage_alert", "event", "over_threshold",
		"day", day, "points", report.total.points(), "threshold", a.threshold, "webhook", a.webhook != "")
	if a.webhook == "" {
		return nil
	}
	return a.post(ctx, content)
}

func tdxUsageAlertContent(day string, report tdxUsageReport, threshold float64) string {
	var b strings.Builder
	fmt.Fprintf(&b, "TDX usage on %s (Taipei) so far: about %.1f points, alert threshold %g. %d calls, %.1f MB.",
		day, report.total.points(), threshold, report.total.calls, tdxMB(report.total.bytes))
	for _, u := range report.names[:min(len(report.names), _tdxUsageTopNames)] {
		fmt.Fprintf(&b, "\n- %s: %.1f MB, %d calls, %d not modified", u.name, tdxMB(u.bytes), u.calls, u.notModified)
	}
	return b.String()
}

type tdxAlertPayload struct {
	Content string `json:"content"`
}

func (a tdxUsageAlert) post(ctx context.Context, content string) error {
	// A struct of one string field always marshals.
	payload, _ := json.Marshal(tdxAlertPayload{Content: content})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.webhook, bytes.NewReader(payload))
	if err != nil {
		return _oops.Wrapf(err, "build TDX usage alert")
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := a.client.Do(req)
	if err != nil {
		return _oops.Wrapf(err, "post TDX usage alert")
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode >= http.StatusMultipleChoices {
		return _oops.With("status", resp.Status).Errorf("TDX usage alert rejected")
	}
	return nil
}

// logTDXUsage reports the previous Taipei day, which is complete whatever time
// of day the cron runs.
func logTDXUsage(rc redis.Cmdable, now time.Time) {
	ctx, cancel := context.WithTimeout(context.Background(), _tdxUsageJobTimeout)
	defer cancel()
	day := shared.TDXUsageDay(now.AddDate(0, 0, -1))
	report, err := readTDXUsage(ctx, rc, day)
	if err != nil {
		zap.S().Warnw("report failed", "component", "tdx", "action", "usage_report", "event", "report_failed", "err", err)
		return
	}
	for _, u := range report.names {
		logTDXUsageLine("name_total", day, u)
	}
	logTDXUsageLine("day_total", day, report.total)
}

func logTDXUsageLine(event, day string, u tdxNameUsage) {
	zap.S().Infow("daily usage", "component", "tdx", "action", "usage_report", "event", event,
		"day", day, "name", u.name, "calls", u.calls, "not_modified", u.notModified, "bytes", u.bytes, "points", u.points())
}
