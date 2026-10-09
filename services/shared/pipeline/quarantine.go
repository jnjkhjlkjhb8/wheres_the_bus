package pipeline

import (
	"errors"
	"os"
	"sort"
	"strconv"
	"strings"

	"go.uber.org/zap"
)

func LogSafeDetail(s string) string {
	return strings.NewReplacer(" ", "_", "=", ":", `"`, "'").Replace(s)
}

func SortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

type Quarantine struct {
	dataset string
	part    string
	dropped map[string]int    // reason -> count
	sample  map[string]string // reason -> first offending record
	kind    map[string]string // reason -> the kind it was dropped from
	seen    map[string]int    // kind -> records examined (the ratio denominator)
}

func NewQuarantine(dataset, part string) *Quarantine {
	return &Quarantine{
		dataset: dataset, part: part,
		dropped: map[string]int{}, sample: map[string]string{},
		kind: map[string]string{}, seen: map[string]int{},
	}
}

// consider records how many records of a kind were examined. It is the
// denominator quarantineRatioLimit gates on, so every kind that can drop must
// declare its total.
func (q *Quarantine) Consider(kind string, n int) {
	q.seen[kind] += n
}

// drop records one rejected record. kind names the section it came from (the
// ratio bucket, e.g. "shape"); reason is the stable log slug; detail
// identifies the offending record so an operator can find it.
func (q *Quarantine) Drop(kind, reason, detail string) {
	q.dropped[reason]++
	q.kind[reason] = kind
	if _, ok := q.sample[reason]; !ok {
		q.sample[reason] = LogSafeDetail(detail)
	}
}

// exceeded reports the kinds whose drop ratio crossed the limit. The caller
// fails the partition on a non-nil error, which leaves the previous load's rows
// in place — stale but whole, which beats fresh but silently gutted.
func (q *Quarantine) Exceeded() error {
	limit := QuarantineRatioLimit()
	byKind := map[string]int{}
	for reason, n := range q.dropped {
		byKind[q.kind[reason]] += n
	}
	var over []error
	for _, kind := range SortedKeys(byKind) {
		seen := q.seen[kind]
		if seen == 0 {
			continue
		}
		ratio := float64(byKind[kind]) / float64(seen)
		if ratio > limit {
			over = append(over, _oops.
				With("kind", kind).
				With("dropped", byKind[kind]).
				With("seen", seen).
				With("ratio", ratio).
				With("limit", limit).
				Errorf("drop ratio exceeded"))
		}
	}
	if len(over) == 0 {
		return nil
	}
	return _oops.With("dataset", q.dataset).With("part", q.part).Wrapf(errors.Join(over...), "quarantine ratio exceeded")
}

// report logs one line per reason with its share of the kind it came from, so a
// tail that stops being a tail is visible before it becomes an outage. A clean
// partition logs nothing.
func (q *Quarantine) Report() {
	for _, r := range SortedKeys(q.dropped) {
		kind := q.kind[r]
		seen := q.seen[kind]
		ratio := 0.0
		if seen > 0 {
			ratio = float64(q.dropped[r]) / float64(seen)
		}
		zap.S().Warnw("dropped",
			"component", "load",
			"action", "quarantine",
			"event", "dropped",
			"dataset", q.dataset,
			"partition", q.part,
			"reason", r,
			"count", q.dropped[r],
			"of", seen,
			"ratio", ratio,
			"first", q.sample[r],
		)
	}
}

func QuarantineRatioLimit() float64 {
	if v := os.Getenv("LOAD_QUARANTINE_MAX_RATIO"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f >= 0 && f <= 1 {
			return f
		}
		zap.S().Warnw("bad ratio env",
			"component", "load",
			"action", "quarantine",
			"event", "bad_ratio_env",
			"value", v,
			"using", _defaultQuarantineRatio,
		)
	}
	return _defaultQuarantineRatio
}

const _defaultQuarantineRatio = 0.10
