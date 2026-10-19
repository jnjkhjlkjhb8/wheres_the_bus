package predict

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/pashagolub/pgxmock/v4"
)

func predictionRows(t *testing.T, data *pgxmock.Rows) pgx.Rows {
	t.Helper()
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	db.ExpectQuery("SELECT").WillReturnRows(data).RowsWillBeClosed()
	rows, err := db.Query(t.Context(), "SELECT")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		rows.Close()
		if err := db.ExpectationsWereMet(); err != nil {
			t.Error(err)
		}
		db.Close()
	})
	return rows
}

func TestDeparturesPreferTimetableAndPreserveFirstEqualPriority(t *testing.T) {
	early := time.Date(2026, 1, 1, 8, 0, 0, 0, time.UTC)
	late := early.Add(time.Hour)
	data := pgxmock.NewRows([]string{"uid", "direction", "departure", "priority"}).
		AddRow("route", "invalid direction", early, 0).
		AddRow("route", int32(0), early, 1).
		AddRow("route", int32(0), late, 0).
		AddRow("route", int32(0), early, 0).
		AddRow("route", int32(0), early, 1)
	got := collectDepartures(predictionRows(t, data), map[RouteDirKey]time.Time{}, 1)
	if len(got) != 1 || !got[RouteDirKey{"route", 0}].Equal(late) {
		t.Fatalf("prioritized departures = %v", got)
	}
}

func TestDeparturesRetainCompletedRowsAfterIterationFailure(t *testing.T) {
	departure := time.Date(2026, 1, 1, 8, 0, 0, 0, time.UTC)
	data := pgxmock.NewRows([]string{"uid", "direction", "departure", "priority"}).
		AddRow("route", int32(0), departure, 0).
		AddRow("other", int32(0), departure, 0).
		RowError(1, errors.New("connection interrupted")).
		CloseError(errors.New("connection interrupted"))
	got := collectDepartures(predictionRows(t, data), map[RouteDirKey]time.Time{}, 2)
	if len(got) != 1 || !got[RouteDirKey{"route", 0}].Equal(departure) {
		t.Fatalf("partial departures = %v", got)
	}
}

func TestStopOffsetRowsSkipMalformedValuesAndDoNotMarkPartialReadComplete(t *testing.T) {
	for _, fail := range []bool{false, true} {
		data := pgxmock.NewRows([]string{"uid", "direction", "stop", "seconds"}).
			AddRow("A", int32(0), "bad", "invalid seconds").
			AddRow("A", int32(1), "stop", 90).
			AddRow("A", int32(1), "other", 120)
		if fail {
			// pgxmock replaces the final row error with its close error at EOF.
			data.RowError(2, errors.New("connection interrupted")).CloseError(errors.New("connection interrupted"))
		}
		out := map[StopOffsetKey]int{}
		fetched, complete := collectStopOffsets(predictionRows(t, data), []string{"A", "B"}, out)
		if out[StopOffsetKey{"A", 1, "stop"}] != 90 || complete == fail {
			t.Fatalf("offsets = %v, complete %v, failure %v", out, complete, fail)
		}
		if fail {
			if fetched != nil {
				t.Fatalf("partial read returned cacheable rows = %v", fetched)
			}
		} else if len(fetched["A"]) != 2 || fetched["B"] != nil || len(out) != 2 {
			t.Fatalf("complete offsets = %v/%v", out, fetched)
		}
	}
}

func TestStaticMapCacheRejectsAbsentAndMalformedEntries(t *testing.T) {
	var cache sync.Map
	if _, ok := CachedStaticMapFrom(&cache, "missing", "", time.Now()); ok {
		t.Fatal("missing map was cached")
	}
	cache.Store("bad", "invalid")
	if _, ok := CachedStaticMapFrom(&cache, "bad", "", time.Now()); ok {
		t.Fatal("malformed map was accepted")
	}
	if _, ok := cache.Load("bad"); ok {
		t.Fatal("malformed map was retained")
	}
}

func TestBatchDepartureEmptyInputAvoidsDatabaseQuery(t *testing.T) {
	if got := BatchNextDepartures(t.Context(), nil, nil, "", 0); len(got) != 0 {
		t.Fatalf("empty departures = %v", got)
	}
}

func TestBatchPredictionDatabaseFailureReturnsNoSyntheticEntries(t *testing.T) {
	db := predictTestPool(t)
	db.Close()
	uid := t.Name()
	if got := BatchNextDepartures(t.Context(), db, []RouteDirKey{{uid, 0}}, "12:00:00", 1); len(got) != 0 {
		t.Fatalf("failed departure query = %v", got)
	}
	if got := BatchStopOffsets(t.Context(), db, []string{uid}); len(got) != 0 {
		t.Fatalf("failed offset query = %v", got)
	}
	if _, ok := _stopOffsetCache.Load(uid); ok {
		t.Fatal("failed offset query was cached")
	}
}

// predictionQueryPool returns a pgxmock pool whose single expected Query
// (matched on its arguments) returns data, so the batched lookups run their
// success path without a live database.
func predictionQueryPool(t *testing.T, args []any, data *pgxmock.Rows) queryer {
	t.Helper()
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	exp := db.ExpectQuery("SELECT")
	if len(args) > 0 {
		exp.WithArgs(args...)
	}
	exp.WillReturnRows(data).RowsWillBeClosed()
	t.Cleanup(func() {
		if err := db.ExpectationsWereMet(); err != nil {
			t.Error(err)
		}
		db.Close()
	})
	return db
}

func TestBatchNextDeparturesReadsRowsOnSuccess(t *testing.T) {
	departure := time.Date(2026, 1, 1, 8, 0, 0, 0, time.UTC)
	data := pgxmock.NewRows([]string{"uid", "direction", "departure", "priority"}).
		AddRow("route", int32(0), departure, 0)
	pool := predictionQueryPool(t, []any{[]string{"route"}, []int32{0}, "07:00:00", 1}, data)
	got := BatchNextDepartures(t.Context(), pool, []RouteDirKey{{"route", 0}}, "07:00:00", 1)
	if !got[RouteDirKey{"route", 0}].Equal(departure) {
		t.Fatalf("departures = %v", got)
	}
}

// predictionErrorPool returns a pool whose Query fails, exercising the
// error branches the real-database tests used to cover.
func predictionErrorPool(t *testing.T, args []any) queryer {
	t.Helper()
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	exp := db.ExpectQuery("SELECT")
	if len(args) > 0 {
		exp.WithArgs(args...)
	}
	exp.WillReturnError(errors.New("query failed"))
	t.Cleanup(func() {
		if err := db.ExpectationsWereMet(); err != nil {
			t.Error(err)
		}
		db.Close()
	})
	return db
}

func TestBatchNextDeparturesQueryFailureReturnsEmptyMap(t *testing.T) {
	pool := predictionErrorPool(t, []any{[]string{"route"}, []int32{0}, "07:00:00", 1})
	if got := BatchNextDepartures(t.Context(), pool, []RouteDirKey{{"route", 0}}, "07:00:00", 1); len(got) != 0 {
		t.Fatalf("failed departure query returned %v", got)
	}
}

func TestLoadStopOffsetsQueryFailureCachesNothing(t *testing.T) {
	uid := t.Name()
	t.Cleanup(func() { _stopOffsetCache.Delete(uid) })
	pool := predictionErrorPool(t, []any{[]string{uid}})
	loadStopOffsets(t.Context(), pool, []string{uid}, map[StopOffsetKey]int{})
	if _, ok := _stopOffsetCache.Load(uid); ok {
		t.Fatal("failed offset query was cached")
	}
}

func TestLoadStopOffsetsCachesOnlyCompleteReads(t *testing.T) {
	complete, partial := "ZZ_OFFSET_COMPLETE", "ZZ_OFFSET_PARTIAL"
	t.Cleanup(func() {
		_stopOffsetCache.Delete(complete)
		_stopOffsetCache.Delete(partial)
	})
	completeRows := pgxmock.NewRows([]string{"uid", "direction", "stop", "seconds"}).
		AddRow(complete, int32(0), "S1", 0).
		AddRow(complete, int32(0), "S2", 90)
	// A readable row followed by a failing scan and close error, so
	// collectStopOffsets reports the read as partial (rows.Err is non-nil).
	partialRows := pgxmock.NewRows([]string{"uid", "direction", "stop", "seconds"}).
		AddRow(partial, int32(0), "S1", 0).
		AddRow(partial, int32(0), "S2", 90).
		RowError(1, errors.New("connection interrupted")).
		CloseError(errors.New("connection interrupted"))

	for _, tc := range []struct {
		name   string
		uid    string
		rows   *pgxmock.Rows
		cached bool
	}{
		{name: "complete read is cached", uid: complete, rows: completeRows, cached: true},
		{name: "partial read is not cached", uid: partial, rows: partialRows, cached: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pool := predictionQueryPool(t, []any{[]string{tc.uid}}, tc.rows)
			loadStopOffsets(t.Context(), pool, []string{tc.uid}, map[StopOffsetKey]int{})
			_, got := _stopOffsetCache.Load(tc.uid)
			if got != tc.cached {
				t.Fatalf("offset cache populated = %v, want %v", got, tc.cached)
			}
		})
	}
}
