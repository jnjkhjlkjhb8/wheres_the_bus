package history

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"
)

// fakeAdmin records the ALTER statements the partition job issues and serves a
// fixed partition list, so the planning can be asserted without a live MySQL.
type fakeAdmin struct {
	byTable map[string][]archivePartition
	stmts   []string
	readErr error
	execErr error
}

func (f *fakeAdmin) ExecContext(_ context.Context, q string, _ ...any) (sql.Result, error) {
	f.stmts = append(f.stmts, q)
	return nil, f.execErr
}

func (f *fakeAdmin) partitions(_ context.Context, table string) ([]archivePartition, error) {
	if f.readErr != nil {
		return nil, f.readErr
	}
	return f.byTable[table], nil
}

func (f *fakeAdmin) stmtsFor(table string) []string {
	var out []string
	for _, s := range f.stmts {
		if strings.Contains(s, " "+table+" ") {
			out = append(out, s)
		}
	}
	return out
}

func month(year int, m time.Month) time.Time {
	return time.Date(year, m, 1, 0, 0, 0, 0, time.UTC)
}

// A bound read back from information_schema is a TO_DAYS number, and the job
// turns it into the date it stands for. If this conversion drifts, partitions
// are dropped against the wrong cutoff — which deletes data, silently.
func TestMySQLDaysRoundTrip(t *testing.T) {
	for _, want := range []time.Time{month(2026, time.September), month(2027, time.January), month(2026, time.August)} {
		if got := fromMySQLDays(toMySQLDays(want)); !got.Equal(want) {
			t.Errorf("round trip of %s gave %s", want.Format(time.DateOnly), got.Format(time.DateOnly))
		}
	}
	// Anchor one real value, so the conversion is right rather than merely
	// self-consistent: TO_DAYS('1970-01-01') is 719528, and 2026-09-01 is 20697
	// days after it.
	if got := toMySQLDays(month(2026, time.September)); got != 740225 {
		t.Errorf("TO_DAYS(2026-09-01) = %d, want 740225", got)
	}
}

// A partition is named for the month it holds, not the month its bound stops at
// — matching the names already in migrations/mysql/2026-08-02-history-partitions.sql.
func TestPartitionNameLabelsTheMonthItHolds(t *testing.T) {
	if got := partitionName(month(2026, time.October)); got != "p2026_09" {
		t.Errorf("partition ending 2026-10-01 named %q, want p2026_09", got)
	}
	if got := partitionName(month(2027, time.January)); got != "p2026_12" {
		t.Errorf("partition ending 2027-01-01 named %q, want p2026_12", got)
	}
}

// The whole reason this job exists: a hand-written partition list runs out and
// pruning stops working without anything failing. Given a table whose declared
// bounds end next month, the job must extend it.
func TestMaintainAddsTheComingMonths(t *testing.T) {
	f := &fakeAdmin{byTable: map[string][]archivePartition{
		"live_archive": {{name: "p2026_08", upper: month(2026, time.September)}},
	}}
	now := time.Date(2026, time.August, 21, 4, 30, 0, 0, time.UTC)

	if err := MaintainPartitions(context.Background(), f, now); err != nil {
		t.Fatalf("maintain: %v", err)
	}
	stmts := f.stmtsFor("live_archive")
	if len(stmts) != 1 {
		t.Fatalf("want one ALTER for live_archive, got %v", stmts)
	}
	for _, want := range []string{"REORGANIZE PARTITION p_max", "p2026_09", "p2026_10", "p2026_11", "p_max VALUES LESS THAN MAXVALUE"} {
		if !strings.Contains(stmts[0], want) {
			t.Errorf("statement missing %q:\n%s", want, stmts[0])
		}
	}
}

// Re-running on an already-maintained table must be a no-op. REORGANIZE rewrites
// the partitions it names, so an unnecessary one is not merely redundant.
func TestMaintainIsQuietWhenPartitionsAlreadyReachAhead(t *testing.T) {
	f := &fakeAdmin{byTable: map[string][]archivePartition{
		"live_archive": {
			{name: "p2026_08", upper: month(2026, time.September)},
			{name: "p2026_09", upper: month(2026, time.October)},
			{name: "p2026_10", upper: month(2026, time.November)},
			{name: "p2026_11", upper: month(2026, time.December)},
		},
	}}
	now := time.Date(2026, time.August, 21, 4, 30, 0, 0, time.UTC)

	if err := MaintainPartitions(context.Background(), f, now); err != nil {
		t.Fatalf("maintain: %v", err)
	}
	if stmts := f.stmtsFor("live_archive"); len(stmts) != 0 {
		t.Errorf("want no ALTER on an up-to-date table, got %v", stmts)
	}
}

// Retention drops whole expired months, and only whole ones: a partition still
// holding rows newer than the cutoff must survive, because dropping it would
// take those rows with it.
func TestMaintainDropsOnlyFullyExpiredPartitions(t *testing.T) {
	f := &fakeAdmin{byTable: map[string][]archivePartition{
		"live_archive_bus": {
			{name: "p2026_02", upper: month(2026, time.March)},
			{name: "p2026_03", upper: month(2026, time.April)},
			// Ends 2026-06-01, inside the 90-day window from 2026-08-21.
			{name: "p2026_05", upper: month(2026, time.June)},
			{name: "p2026_08", upper: month(2026, time.September)},
		},
	}}
	now := time.Date(2026, time.August, 21, 4, 30, 0, 0, time.UTC)

	if err := MaintainPartitions(context.Background(), f, now); err != nil {
		t.Fatalf("maintain: %v", err)
	}
	var drop string
	for _, s := range f.stmts {
		if strings.Contains(s, "DROP PARTITION") {
			drop = s
		}
	}
	if drop == "" {
		t.Fatal("want a DROP for the expired months")
	}
	for _, want := range []string{"p2026_02", "p2026_03"} {
		if !strings.Contains(drop, want) {
			t.Errorf("statement should drop %s:\n%s", want, drop)
		}
	}
	if strings.Contains(drop, "p2026_05") || strings.Contains(drop, "p2026_08") {
		t.Errorf("statement drops a partition still inside the retention window:\n%s", drop)
	}
}

// A table kept indefinitely gets its partitions created and never dropped. This
// is the difference between the two live_archive tables, and getting it wrong
// deletes the metro congestion history that has no second source.
func TestMaintainNeverDropsFromIndefiniteTables(t *testing.T) {
	f := &fakeAdmin{byTable: map[string][]archivePartition{
		"live_archive":    {{name: "p2024_01", upper: month(2024, time.February)}},
		"bus_eta_history": {{name: "p2024_01", upper: month(2024, time.February)}},
	}}
	now := time.Date(2026, time.August, 21, 4, 30, 0, 0, time.UTC)

	if err := MaintainPartitions(context.Background(), f, now); err != nil {
		t.Fatalf("maintain: %v", err)
	}
	for _, s := range f.stmts {
		if strings.Contains(s, "DROP PARTITION") {
			t.Errorf("dropped from an indefinitely-kept table: %s", s)
		}
	}
}

// One unreadable table must not leave the others unmaintained — including the
// pruned one, whose partitions are what bounds the disk.
func TestMaintainReportsFailureWithoutAbandoningTheRest(t *testing.T) {
	f := &fakeAdmin{readErr: errors.New("archive host down")}
	err := MaintainPartitions(context.Background(), f, time.Now())
	if err == nil {
		t.Fatal("want the read failure reported")
	}
	if got := strings.Count(err.Error(), "archive host down"); got != len(_archivePartitionTables) {
		t.Errorf("reported %d table failures, want one per managed table (%d)", got, len(_archivePartitionTables))
	}
}

// Every environment but prod has no archive host, and the daily job runs there
// too.
func TestMaintainWithoutAnArchiveHostIsANoOp(t *testing.T) {
	if err := MaintainPartitions(context.Background(), nil, time.Now()); err != nil {
		t.Errorf("want a silent skip, got %v", err)
	}
}
