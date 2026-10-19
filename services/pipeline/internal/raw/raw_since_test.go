package raw

import (
	"context"
	"github.com/jackc/pgx/v5/pgxpool"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestRawSinceQueriesKeepExactAndPartitionedTargetsDistinct(t *testing.T) {
	for _, name := range []string{"tra_stations", "thsr_stations", "tra_fare", "thsr_fare"} {
		q, arg := rawSinceQuery(name)
		if q == "" || arg != nil || strings.Contains(q, "WHERE") {
			t.Fatalf("%s: query %q, argument %v", name, q, arg)
		}
	}
	for _, name := range []string{"tra_traindate_2026-10-10", "thsr_traindate_2026-10-10", "mrt_stationsTRTC", "mrt_firstlastTRTC", "bike_stationsTaipei"} {
		q, arg := rawSinceQuery(name)
		if !strings.Contains(q, "WHERE") || arg == nil {
			t.Fatalf("%s: query %q, argument %v", name, q, arg)
		}
	}
	if q, arg := rawSinceQuery("unknown"); q != "" || arg != nil {
		t.Fatalf("unknown query %q, %v", q, arg)
	}
	previous := DB
	DB = nil
	t.Cleanup(func() { DB = previous })
	if got := dbSince("tra_stations"); got != "" {
		t.Fatalf("nil pool: %q", got)
	}
}

func TestRawSinceUsesUTCAndPartitionFiltersAgainstDatabase(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required")
		}
		t.Skip("DATABASE_URL not set")
	}
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.MaxConns = 1
	pool, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	previous, enabled := DB, DumpEnabled
	DB, DumpEnabled = pool, false
	t.Cleanup(func() { DB, DumpEnabled = previous, enabled })
	ctx := context.Background()
	for _, query := range []string{
		`CREATE TEMP TABLE tra_stations (updated_at timestamptz)`,
		`CREATE TEMP TABLE tra_timetable (train_date date, updated_at timestamptz)`,
	} {
		if _, err := pool.Exec(ctx, query); err != nil {
			t.Fatal(err)
		}
	}
	if got := dbSince("tra_stations"); got != "" {
		t.Fatalf("empty table: %q", got)
	}
	stamp := time.Date(2026, 10, 10, 8, 9, 10, 0, time.FixedZone("west", -8*60*60))
	if _, err := pool.Exec(ctx, `INSERT INTO tra_stations VALUES ($1)`, stamp); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO tra_timetable VALUES ('2026-10-10', $1), ('2026-10-11', $2)`, stamp, stamp.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	want := stamp.UTC().Format(http.TimeFormat)
	for _, name := range []string{"tra_stations", "tra_traindate_2026-10-10"} {
		if got := SinceFallback(name); got != want {
			t.Fatalf("%s: %q, want %q", name, got, want)
		}
	}
	if got := dbSince("unsupported"); got != "" {
		t.Fatalf("unsupported dataset: %q", got)
	}
	DumpEnabled = true
	if got := SinceFallback("tra_stations"); got != "" {
		t.Fatalf("ingestor fallback unexpectedly used live data: %q", got)
	}
}
