package vector

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/searchalias"
	"github.com/pashagolub/pgxmock/v4"
	"github.com/redis/go-redis/v9"
)

type testVectorRedis struct {
	value          string
	getErr         error
	setErr         error
	setValues      []string
	successfulSets int
}

func (r *testVectorRedis) Get(context.Context, string) *redis.StringCmd {
	return redis.NewStringResult(r.value, r.getErr)
}

func (r *testVectorRedis) Set(_ context.Context, _ string, value any, _ time.Duration) *redis.StatusCmd {
	r.setValues = append(r.setValues, fmt.Sprint(value))
	if r.setErr == nil {
		r.successfulSets++
	}
	return redis.NewStatusResult("OK", r.setErr)
}

type captureTimeArgs struct {
	values []time.Time
}

type capturingBatchDB struct {
	pgxmock.PgxPoolIface
	batch    *pgx.Batch
	closeErr error
}

func (db *capturingBatchDB) SendBatch(_ context.Context, batch *pgx.Batch) pgx.BatchResults {
	db.batch = batch
	return closeErrorBatchResults{err: db.closeErr}
}

type closeErrorBatchResults struct {
	err error
}

func (r closeErrorBatchResults) Exec() (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, r.err
}

func (r closeErrorBatchResults) Query() (pgx.Rows, error) {
	return nil, r.err
}

func (r closeErrorBatchResults) QueryRow() pgx.Row {
	return nil
}

func (r closeErrorBatchResults) Close() error {
	return r.err
}

func (c *captureTimeArgs) Match(value any) bool {
	cutoff, ok := value.(time.Time)
	if ok {
		c.values = append(c.values, cutoff)
	}
	return ok
}

func newVectorDBMock(t *testing.T) pgxmock.PgxPoolIface {
	t.Helper()
	db, err := pgxmock.NewPool(pgxmock.QueryMatcherOption(pgxmock.QueryMatcherEqual))
	if err != nil {
		t.Fatalf("pgxmock.NewPool: %v", err)
	}
	t.Cleanup(db.Close)
	return db
}

func expectEmptyVectorQueries(db pgxmock.PgxPoolIface, lower string, cutoff pgxmock.Argument) {
	for _, dataset := range _vectorDatasets {
		db.ExpectQuery(dataset.query).
			WithArgs(dataset.queryArgs(lower, cutoff)...).
			WillReturnRows(db.NewRows([]string{"unused"}))
	}
}

func vectorDatasetByType(t *testing.T, vectorType string) vectorDataset {
	t.Helper()
	for _, dataset := range _vectorDatasets {
		if dataset.vectorType == vectorType {
			return dataset
		}
	}
	t.Fatalf("vector dataset %q not found", vectorType)
	return vectorDataset{}
}

func validBusVectorRows(db pgxmock.PgxPoolIface) *pgxmock.Rows {
	return db.NewRows([]string{"sub_route_uid", "sub_route_name", "city", "depart", "destin"}).
		AddRow("R1", "藍線", "Taipei", "台北車站", "市政府")
}

func TestVectorRegistryIncludesAllSixDatasetsExactlyOnce(t *testing.T) {
	want := map[string]int{
		"bus_route":    1,
		"bus_station":  1,
		"bike_station": 1,
		"mrt_station":  1,
		"tra_station":  1,
		"thsr_station": 1,
	}
	got := make(map[string]int, len(want))
	for _, dataset := range _vectorDatasets {
		got[dataset.vectorType]++
	}
	for vectorType, wantCount := range want {
		if got[vectorType] != wantCount {
			t.Errorf("vector type %q occurs %d times, want %d", vectorType, got[vectorType], wantCount)
		}
	}
	if len(_vectorDatasets) != len(want) {
		t.Errorf("registry contains %d datasets, want %d", len(_vectorDatasets), len(want))
	}
}

func TestVectorRegistryUsesCorrectMRTLabels(t *testing.T) {
	for code, want := range map[string]string{
		"KLRT": "高雄輕軌",
		"TYMC": "桃園捷運",
	} {
		if got := mrtSystemName(code); got != want {
			t.Errorf("mrtSystemName(%q) = %q, want %q", code, got, want)
		}
	}
	if _, ok := _mrtSystemNames["NTMC"]; !ok {
		t.Error("mrtSystemNames is missing NTMC")
	}
}

func TestMRTVectorQueryBackfillsLegacyRevisionBeforeLowerWatermark(t *testing.T) {
	dataset := vectorDatasetByType(t, "mrt_station")
	for _, want := range []string{
		"ms.updated_at < $1",
		"NOT EXISTS",
		"sv.city = CASE ms.system",
		"sv.depart = ms.system",
	} {
		if !strings.Contains(_mrtStationsForVectorSQL, want) {
			t.Errorf("MRT vector query missing %q: %s", want, _mrtStationsForVectorSQL)
		}
	}
	for _, unwanted := range []string{"ms.updated_at >=", "$2", "current_sv"} {
		if strings.Contains(_mrtStationsForVectorSQL, unwanted) {
			t.Errorf("MRT vector query contains redundant %q: %s", unwanted, _mrtStationsForVectorSQL)
		}
	}
	if got := strings.Count(_mrtStationsForVectorSQL, "NOT EXISTS"); got != 1 {
		t.Errorf("MRT vector query has %d correlated freshness lookups, want 1: %s", got, _mrtStationsForVectorSQL)
	}
	upper := time.Date(2026, 7, 14, 1, 0, 0, 0, time.UTC)
	args := dataset.queryArgs("ignored lower watermark", upper)
	if len(args) != 1 || args[0] != upper {
		t.Fatalf("MRT query args = %v, want upper cutoff only", args)
	}
}

func TestMRTFailuresDoNotDeleteLegacyVectorsBeforeReplacement(t *testing.T) {
	dataset := vectorDatasetByType(t, "mrt_station")
	const lower = "2026-07-14T00:00:00Z"
	upper := time.Date(2026, 7, 14, 1, 0, 0, 0, time.UTC)

	t.Run("query", func(t *testing.T) {
		db := newVectorDBMock(t)
		wantErr := errors.New("MRT query failed")
		db.ExpectQuery(dataset.query).
			WithArgs(dataset.queryArgs(lower, upper)...).
			WillReturnError(wantErr)

		err := processVectorDataset(context.Background(), db, dataset, lower, upper)
		if !errors.Is(err, wantErr) {
			t.Fatalf("processVectorDataset() error = %v, want wrapped %v", err, wantErr)
		}
		if err := db.ExpectationsWereMet(); err != nil {
			t.Fatalf("database expectations: %v", err)
		}
	})

	t.Run("upsert", func(t *testing.T) {
		pool := newVectorDBMock(t)
		wantErr := errors.New("MRT upsert failed")
		pool.ExpectQuery(dataset.query).
			WithArgs(dataset.queryArgs(lower, upper)...).
			WillReturnRows(pool.NewRows([]string{"station_id", "name", "system", "geom"}).
				AddRow("KLRT-C01", "籬仔內", "KLRT", "POINT(120 22)"))
		db := &capturingBatchDB{PgxPoolIface: pool, closeErr: wantErr}

		err := processVectorDataset(context.Background(), db, dataset, lower, upper)
		if !errors.Is(err, wantErr) {
			t.Fatalf("processVectorDataset() error = %v, want wrapped %v", err, wantErr)
		}
		if db.batch == nil || db.batch.Len() != 2 {
			t.Fatalf("atomic MRT batch length = %v, want upsert plus cleanup", db.batch)
		}
		if db.batch.QueuedQueries[0].SQL != _searchVectorUpsertSQL || db.batch.QueuedQueries[1].SQL != _mrtLegacyVectorCleanupSQL {
			t.Fatalf("MRT batch order = [%q, %q], want upsert then cleanup",
				db.batch.QueuedQueries[0].SQL, db.batch.QueuedQueries[1].SQL)
		}
		if err := pool.ExpectationsWereMet(); err != nil {
			t.Fatalf("database expectations: %v", err)
		}
	})

	t.Run("cleanup", func(t *testing.T) {
		db := newVectorDBMock(t)
		wantErr := errors.New("MRT cleanup failed")
		db.ExpectQuery(dataset.query).
			WithArgs(dataset.queryArgs(lower, upper)...).
			WillReturnRows(db.NewRows([]string{"station_id", "name", "system", "geom"}).
				AddRow("KLRT-C01", "籬仔內", "KLRT", "POINT(120 22)"))
		batch := db.ExpectBatch()
		batch.ExpectExec(_searchVectorUpsertSQL).
			WithArgs("mrt_station", "KLRT-C01", "籬仔內", searchalias.SearchAlias("籬仔內"),
				"高雄輕軌", "KLRT", "", "POINT(120 22)").
			WillReturnResult(pgxmock.NewResult("INSERT", 1))
		batch.ExpectExec(_mrtLegacyVectorCleanupSQL).
			WithArgs("KLRT-C01", "桃園捷運", "KLRT").
			WillReturnError(wantErr)

		err := processVectorDataset(context.Background(), db, dataset, lower, upper)
		if !errors.Is(err, wantErr) {
			t.Fatalf("processVectorDataset() error = %v, want wrapped %v", err, wantErr)
		}
		if err := db.ExpectationsWereMet(); err != nil {
			t.Fatalf("database expectations: %v", err)
		}
	})
}

func TestMRTLegacyLabelsAreInvalidatedBackfilledAndReembedded(t *testing.T) {
	dataset := vectorDatasetByType(t, "mrt_station")
	for _, want := range []string{
		"DELETE FROM search_vector",
		"stale_ms.station_id = stale_sv.uid",
		"stale_ms.system = $3",
		"keeper_ms.station_id = stale_sv.uid",
		"CASE keeper_ms.system",
		"= stale_sv.city",
	} {
		if !strings.Contains(_mrtLegacyVectorCleanupSQL, want) {
			t.Errorf("MRT cleanup SQL missing %q: %s", want, _mrtLegacyVectorCleanupSQL)
		}
	}

	db := newVectorDBMock(t)
	const lower = "2026-07-14T00:00:00Z"
	upper := time.Date(2026, 7, 14, 1, 0, 0, 0, time.UTC)
	db.ExpectQuery(dataset.query).
		WithArgs(dataset.queryArgs(lower, upper)...).
		WillReturnRows(db.NewRows([]string{"station_id", "name", "system", "geom"}).
			AddRow("shared", "輕軌轉乘站", "KLRT", "POINT(120 22)").
			AddRow("shared", "機捷轉乘站", "TYMC", "POINT(121 25)").
			AddRow("N01", "新北產業園區", "NTMC", "POINT(121.4 25.1)"))
	batch := db.ExpectBatch()
	batch.ExpectExec(_searchVectorUpsertSQL).
		WithArgs("mrt_station", "shared", "輕軌轉乘站", searchalias.SearchAlias("輕軌轉乘站"),
			"高雄輕軌", "KLRT", "", "POINT(120 22)").
		WillReturnResult(pgxmock.NewResult("INSERT", 1))
	batch.ExpectExec(_mrtLegacyVectorCleanupSQL).
		WithArgs("shared", "桃園捷運", "KLRT").
		WillReturnResult(pgxmock.NewResult("DELETE", 0))
	batch.ExpectExec(_searchVectorUpsertSQL).
		WithArgs("mrt_station", "shared", "機捷轉乘站", searchalias.SearchAlias("機捷轉乘站"),
			"桃園捷運", "TYMC", "", "POINT(121 25)").
		WillReturnResult(pgxmock.NewResult("INSERT", 1))
	batch.ExpectExec(_mrtLegacyVectorCleanupSQL).
		WithArgs("shared", "台中捷運", "TYMC").
		WillReturnResult(pgxmock.NewResult("DELETE", 1))
	batch.ExpectExec(_searchVectorUpsertSQL).
		WithArgs("mrt_station", "N01", "新北產業園區", searchalias.SearchAlias("新北產業園區"),
			"新北捷運", "NTMC", "", "POINT(121.4 25.1)").
		WillReturnResult(pgxmock.NewResult("INSERT", 1))
	batch.ExpectExec(_mrtLegacyVectorCleanupSQL).
		WithArgs("N01", "NTMC", "NTMC").
		WillReturnResult(pgxmock.NewResult("DELETE", 1))

	if err := processVectorDataset(context.Background(), db, dataset, lower, upper); err != nil {
		t.Fatalf("processVectorDataset() error = %v", err)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatalf("database expectations: %v", err)
	}
}

func TestChangeToVectorCapturesCutoffBeforeFirstQuery(t *testing.T) {
	const lower = "2026-07-13T00:00:00Z"
	db := newVectorDBMock(t)
	cutoffs := &captureTimeArgs{}
	expectEmptyVectorQueries(db, lower, cutoffs)
	cache := &testVectorRedis{value: lower}

	if err := ChangeToVector(context.Background(), cache, db); err != nil {
		t.Fatalf("ChangeToVector() error = %v", err)
	}
	if len(cutoffs.values) != len(_vectorDatasets) {
		t.Fatalf("captured %d cutoffs, want %d", len(cutoffs.values), len(_vectorDatasets))
	}
	for i, got := range cutoffs.values[1:] {
		if !got.Equal(cutoffs.values[0]) {
			t.Errorf("query %d cutoff = %s, first query cutoff = %s", i+2, got, cutoffs.values[0])
		}
	}
	wantWatermark := cutoffs.values[0].Format(time.RFC3339Nano)
	if len(cache.setValues) != 1 || cache.setValues[0] != wantWatermark {
		t.Fatalf("watermark writes = %v, want [%s]", cache.setValues, wantWatermark)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatalf("database expectations: %v", err)
	}
}

func TestChangeToVectorDoesNotAdvanceWatermarkOnAnyFailure(t *testing.T) {
	const lower = "2026-07-13T00:00:00Z"
	wantErr := errors.New("vector dependency failed")
	for _, failure := range []string{
		"redis get",
		"query",
		"scan",
		"rows",
		"batch",
		"redis set",
	} {
		t.Run(failure, func(t *testing.T) {
			db := newVectorDBMock(t)
			cache := &testVectorRedis{value: lower}
			switch failure {
			case "redis get":
				cache.getErr = wantErr
			case "query":
				db.ExpectQuery(_vectorDatasets[0].query).
					WithArgs(lower, pgxmock.AnyArg()).
					WillReturnError(wantErr)
			case "scan":
				db.ExpectQuery(_vectorDatasets[0].query).
					WithArgs(lower, pgxmock.AnyArg()).
					WillReturnRows(db.NewRows([]string{"sub_route_uid"}).AddRow("R1"))
			case "rows":
				db.ExpectQuery(_vectorDatasets[0].query).
					WithArgs(lower, pgxmock.AnyArg()).
					WillReturnRows(validBusVectorRows(db).RowError(0, wantErr))
			case "batch":
				db.ExpectQuery(_vectorDatasets[0].query).
					WithArgs(lower, pgxmock.AnyArg()).
					WillReturnRows(validBusVectorRows(db))
				batch := db.ExpectBatch()
				batch.ExpectExec(_searchVectorUpsertSQL).
					WithArgs(
						pgxmock.AnyArg(), pgxmock.AnyArg(), pgxmock.AnyArg(), pgxmock.AnyArg(),
						pgxmock.AnyArg(), pgxmock.AnyArg(), pgxmock.AnyArg(), pgxmock.AnyArg(),
					).
					WillReturnError(wantErr)
			case "redis set":
				expectEmptyVectorQueries(db, lower, pgxmock.AnyArg())
				cache.setErr = wantErr
			}

			err := ChangeToVector(context.Background(), cache, db)
			if err == nil {
				t.Fatal("ChangeToVector() error = nil, want failure")
			}
			if failure == "scan" {
				if !errMentions(err, "scan") {
					t.Fatalf("ChangeToVector() error = %v, want scan error", err)
				}
			} else if !errors.Is(err, wantErr) {
				t.Fatalf("ChangeToVector() error = %v, want wrapped %v", err, wantErr)
			}
			if cache.successfulSets != 0 {
				t.Fatalf("successful watermark writes = %d, want 0", cache.successfulSets)
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatalf("database expectations: %v", err)
			}
		})
	}
}

func TestVectorQueriesSkipFreshRows(t *testing.T) {
	queries := map[string]string{
		"bus_route":    _busSubroutesForVectorSQL,
		"bus_station":  _busStationsForVectorSQL,
		"bike_station": _bikeStationsForVectorSQL,
		"mrt_station":  _mrtStationsForVectorSQL,
		"thsr_station": _thsrStationsForVectorSQL,
		"tra_station":  _traStationsForVectorSQL,
	}
	for vectorType, query := range queries {
		for _, want := range []string{
			"NOT EXISTS",
			"sv.type = '" + vectorType + "'",
			"sv.alias IS NOT NULL",
		} {
			if !strings.Contains(query, want) {
				t.Fatalf("%s query missing %q", vectorType, want)
			}
		}
		if vectorType == "mrt_station" {
			if !strings.Contains(query, "updated_at < $1") {
				t.Fatalf("%s query missing upper-only cutoff", vectorType)
			}
		} else {
			for _, want := range []string{"updated_at >= $1", "updated_at < $2"} {
				if !strings.Contains(query, want) {
					t.Fatalf("%s query missing %q", vectorType, want)
				}
			}
		}
		if strings.Contains(query, "sv.updated_at >=") {
			t.Fatalf("%s query still compares updated_at: %s", vectorType, query)
		}
	}
}

func TestFreshVectorSkipSQLComparesContent(t *testing.T) {
	got := FreshVectorSkipSQL("bus_route", "bs.sub_route_uid", "sv.name = bs.sub_route_name AND sv.depart = bs.depart AND sv.destin = bs.destin")
	if !strings.Contains(got, "sv.name = bs.sub_route_name") {
		t.Fatalf("missing content predicate: %s", got)
	}
	if strings.Contains(got, "sv.updated_at >=") {
		t.Fatalf("still compares updated_at: %s", got)
	}
}
