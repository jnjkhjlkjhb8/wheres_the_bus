package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
)

// demandRows serves reminder rows without a database: each row is a city
// prefix and an expiry, and scanErr fails the row at that index.
type demandRows struct {
	pgx.Rows
	rows    []time.Time
	prefix  string
	next    int
	scanErr map[int]error
	err     error
}

func (r *demandRows) Next() bool {
	r.next++
	return r.next <= len(r.rows)
}

func (r *demandRows) Scan(dest ...any) error {
	if err := r.scanErr[r.next-1]; err != nil {
		return err
	}
	*dest[0].(*string) = r.prefix
	*dest[1].(*time.Time) = r.rows[r.next-1]
	return nil
}

func (r *demandRows) Err() error { return r.err }

func TestTouchReminderDemandFailsWholeRestoreOnRowErrors(t *testing.T) {
	scanErr, rowsErr := errors.New("scan failed"), errors.New("rows failed")
	expires := time.Now().Add(time.Hour)
	for _, tc := range []struct {
		name string
		rows *demandRows
		want error
	}{
		{"scan error after a good row", &demandRows{rows: []time.Time{expires, expires}, prefix: "TPE", scanErr: map[int]error{1: scanErr}}, scanErr},
		{"rows error after a good row", &demandRows{rows: []time.Time{expires}, prefix: "TPE", err: rowsErr}, rowsErr},
	} {
		t.Run(tc.name, func(t *testing.T) {
			restored, err := touchReminderDemand(t.Context(), tc.rows, recordingDemand{})
			if restored != 0 || !errors.Is(err, tc.want) {
				t.Fatalf("restored=%d err=%v", restored, err)
			}
			if got := reportRestoredDemand(restored, err); got != 0 {
				t.Fatalf("reported %d after a failed restore", got)
			}
		})
	}
}

func TestTouchDemandRowReportsNothingForAFailedScan(t *testing.T) {
	scanErr := errors.New("scan failed")
	rows := &demandRows{rows: []time.Time{time.Now().Add(time.Hour)}, prefix: "TPE", scanErr: map[int]error{0: scanErr}}
	rows.Next()
	live := recordingDemand{}
	touched, err := touchDemandRow(context.Background(), rows, live, time.Now())
	if touched != 0 || !errors.Is(err, scanErr) || len(live) != 0 {
		t.Fatalf("touched=%d err=%v claims=%v", touched, err, live)
	}
}

func TestReportRestoredDemandCountsEveryRestoredCity(t *testing.T) {
	if got := reportRestoredDemand(2, nil); got != 2 {
		t.Fatalf("reported %d", got)
	}
	if got := reportRestoredDemand(0, nil); got != 0 {
		t.Fatalf("reported %d", got)
	}
	live := recordingDemand{}
	rows := &demandRows{rows: []time.Time{time.Now().Add(time.Hour)}, prefix: "KHH"}
	if restored, err := touchReminderDemand(t.Context(), rows, live); restored != 1 || err != nil || live[shared.LiveDemandKey("bus_eta", "Kaohsiung")] <= 0 {
		t.Fatalf("restored=%d err=%v claims=%v", restored, err, live)
	}
}
