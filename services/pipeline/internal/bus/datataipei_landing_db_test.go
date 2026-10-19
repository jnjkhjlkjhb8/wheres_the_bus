package bus

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
)

func TestDataTaipeiLandingUsesServiceDayAndDurableRawPartition(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required")
		}
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	admin, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(admin.Close)
	name := fmt.Sprintf("bus_landing_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(context.Background(), "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)"); err != nil {
			t.Error(err)
		}
	})
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.Database = name
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	for _, ddl := range []string{
		`CREATE SCHEMA raw_tdx`,
		`CREATE TABLE raw_tdx.bus_dailytimetable(city text,subrouteuid text,direction smallint,busdate date,timetables jsonb)`,
		`CREATE TABLE raw_tdx.landing_state(table_name text,partition_column text,partition_value text,last_modified text,row_count bigint,fetched_at timestamptz,landing_cycle text,PRIMARY KEY(table_name,partition_column,partition_value))`,
	} {
		if _, err := pool.Exec(ctx, ddl); err != nil {
			t.Fatal(err)
		}
	}
	previous := raw.DB
	raw.DB = pool
	t.Cleanup(func() { raw.DB = previous })
	status := http.StatusOK
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(`{"specificTimeTables":{"specificTimeTable":[{"subRouteID":"100","direction":"0","timeTables":{"timeTable":[{"stopTimes":{"stopTime":[{"stopSequence":1,"stopID":"S1","arrivalTime":"06:00","departureTime":"06:01"}]},"specialDays":{"specialDay":[{"serviceStatus":"1","dates":{"date":["2026-10-11"]}}]}}]}}]}}`))
	}))
	t.Cleanup(server.Close)
	feed := &dataTaipeiFeed{client: resty.New().SetBaseURL(server.URL), city: "Taipei", etag: map[string]string{}}
	clock := func() time.Time { return time.Date(2026, 10, 10, 17, 0, 0, 0, time.UTC) }
	if err := LandDataTaipeiDailyTimetable(ctx, feed, clock); err != nil {
		t.Fatal(err)
	}
	var uid, marker, cycle string
	var rows int
	if err := pool.QueryRow(ctx, `SELECT subrouteuid FROM raw_tdx.bus_dailytimetable WHERE city='Taipei' AND busdate='2026-10-11'`).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	if uid != "TPE100" {
		t.Fatalf("landed UID = %s", uid)
	}
	if err := pool.QueryRow(ctx, `SELECT last_modified,row_count,landing_cycle FROM raw_tdx.landing_state WHERE table_name='bus_dailytimetable' AND partition_value='Taipei'`).Scan(&marker, &rows, &cycle); err != nil {
		t.Fatal(err)
	}
	if marker != "datataipei:2026-10-11" || rows != 1 || cycle == "" {
		t.Fatalf("landing metadata = %s / %d / %q", marker, rows, cycle)
	}
	raw.DB = nil
	if err := LandDataTaipeiDailyTimetable(ctx, feed, clock); err == nil {
		t.Fatal("missing raw DB accepted")
	}
	status = http.StatusBadGateway
	if err := LandDataTaipeiDailyTimetable(ctx, feed, clock); err == nil {
		t.Fatal("failed timetable fetch accepted")
	}
}
