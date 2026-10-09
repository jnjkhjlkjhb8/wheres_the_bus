// Package holiday tracks which dates run a holiday timetable. Taiwan's calendar
// moves working days around national holidays, so the answer comes from the
// published calendar rather than from the day of the week.
package holiday

import (
	"context"
	"encoding/csv"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
)

const _holidayCSVURL = "https://data.ntpc.gov.tw/api/datasets/308dcd75-6434-45bc-a95f-584da4fed251/csv/file"

const HTTPTimeout = 15 * time.Second

type holidaySnapshot struct {
	dates map[string]bool
}

var _currentHolidaySnapshot atomic.Pointer[holidaySnapshot]

// Load fetches one complete immutable snapshot. The atomic pointer is
// swapped only after status, body, and CSV validation succeed, preserving the
// last good snapshot across transient refresh failures.
func Load(ctx context.Context) error {
	client := &http.Client{Timeout: HTTPTimeout}
	return refreshHolidays(ctx, client, _holidayCSVURL)
}

func refreshHolidays(ctx context.Context, client *http.Client, url string) error {
	if ctx == nil {
		return errors.New("holiday refresh context is nil")
	}
	if client == nil {
		return errors.New("holiday HTTP client is nil")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return _oops.Wrapf(err, "create holiday request")
	}
	resp, err := client.Do(req)
	if err != nil {
		return _oops.Wrapf(err, "fetch holiday CSV")
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		_, drainErr := io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		return errors.Join(_oops.With("status_code", resp.StatusCode).Errorf("fetch holiday CSV: HTTP status"), drainErr)
	}
	dates, err := parseHolidayCSV(resp.Body)
	if err != nil {
		return _oops.Wrapf(err, "parse holiday CSV")
	}
	_currentHolidaySnapshot.Store(&holidaySnapshot{dates: dates})
	zap.S().Infow("loaded entries", "component", "holiday", "entries", len(dates))
	return nil
}

func parseHolidayCSV(r io.Reader) (map[string]bool, error) {
	csvReader := csv.NewReader(r)
	if _, err := csvReader.Read(); err != nil {
		return nil, _oops.Wrapf(err, "read header")
	}
	dates := make(map[string]bool)
	for {
		record, err := csvReader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, _oops.Wrapf(err, "read row")
		}
		if len(record) < 4 {
			return nil, _oops.With("record", len(record)).Errorf("row has columns, want at least 4")
		}
		rawDate := strings.TrimSpace(record[0])
		date, err := time.Parse("20060102", rawDate)
		if err != nil {
			return nil, _oops.With("raw_date", rawDate).Wrapf(err, "date")
		}
		dates[date.Format(time.DateOnly)] = strings.TrimSpace(record[3]) == "是"
	}
	if len(dates) == 0 {
		return nil, errors.New("holiday CSV contains no data rows")
	}
	return dates, nil
}

func storeHolidaySnapshot(dates map[string]bool) {
	if dates == nil {
		_currentHolidaySnapshot.Store(nil)
		return
	}
	copyOfDates := make(map[string]bool, len(dates))
	for date, holiday := range dates {
		copyOfDates[date] = holiday
	}
	_currentHolidaySnapshot.Store(&holidaySnapshot{dates: copyOfDates})
}

// IsHoliday first honors an explicit dataset entry, including weekend working
// days, then falls back to Saturday/Sunday when that date is absent.
func IsHoliday(t time.Time) bool {
	local := t.In(pipeline.Taipei)
	if snapshot := _currentHolidaySnapshot.Load(); snapshot != nil {
		if holiday, ok := snapshot.dates[local.Format(time.DateOnly)]; ok {
			return holiday
		}
	}
	return local.Weekday() == time.Saturday || local.Weekday() == time.Sunday
}
