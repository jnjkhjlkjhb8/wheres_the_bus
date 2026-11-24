package history

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

// segmentEtaTestPool connects to DATABASE_URL and skips when it is unset, the
// same shape cleanupTestPool uses.
func segmentEtaTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set; skipping segment-from-estimates integration test")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	return pool
}

func TestFillSegmentTimesFromDistance(t *testing.T) {
	pool := segmentEtaTestPool(t)
	defer pool.Close()
	ctx := context.Background()

	if _, err := pool.Exec(ctx, `SELECT ST_DistanceSphere(
		ST_SetSRID(ST_MakePoint(121.5,25.0),4326), ST_SetSRID(ST_MakePoint(121.5,25.01),4326))`); err != nil {
		t.Skipf("PostGIS not available: %v", err)
	}
	ddl := []string{
		`CREATE TABLE IF NOT EXISTS bus_segment_time (
			sub_route_uid text NOT NULL, direction smallint NOT NULL,
			from_stop_uid text NOT NULL, to_stop_uid text NOT NULL,
			secs int NOT NULL, sample_count int NOT NULL,
			updated_at timestamptz NOT NULL DEFAULT NOW(),
			PRIMARY KEY (sub_route_uid, direction, from_stop_uid, to_stop_uid))`,
		`CREATE TABLE IF NOT EXISTS bus_stations (
			station_uid text PRIMARY KEY, station_name text NOT NULL, city text NOT NULL,
			position geometry(Point,4326), updated_at timestamptz DEFAULT CURRENT_TIMESTAMP)`,
		`CREATE TABLE IF NOT EXISTS bus_station_stop_map (
			station_id text NOT NULL, sub_route_uid text NOT NULL, direction int NOT NULL,
			route_name text, stop_uid text NOT NULL, stop_sequence int, station_name text,
			updated_at timestamptz NOT NULL DEFAULT now())`,
	}
	for _, stmt := range ddl {
		if _, err := pool.Exec(ctx, stmt); err != nil {
			t.Fatalf("ddl: %v", err)
		}
	}

	const uid = "TESTFILL0001"
	cleanup := func() {
		_, _ = pool.Exec(ctx, `DELETE FROM bus_station_stop_map WHERE sub_route_uid = $1`, uid)
		_, _ = pool.Exec(ctx, `DELETE FROM bus_segment_time WHERE sub_route_uid = $1`, uid)
		_, _ = pool.Exec(ctx, `DELETE FROM bus_stations WHERE station_uid LIKE 'TESTFILLST%'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	// Three stops on one line, each hop the same 1 km, so the estimate for the
	// second hop must land on the first hop's observed 200s.
	for i, lon := range []float64{121.500, 121.510, 121.520} {
		if _, err := pool.Exec(ctx, `
			INSERT INTO bus_stations (station_uid, station_name, city, position)
			VALUES ($1, 'st', 'TestCity', ST_SetSRID(ST_MakePoint($2, 25.0), 4326))`,
			fmt.Sprintf("TESTFILLST%d", i+1), lon); err != nil {
			t.Fatalf("insert station: %v", err)
		}
		if _, err := pool.Exec(ctx, `
			INSERT INTO bus_station_stop_map
			  (station_id, sub_route_uid, direction, stop_uid, stop_sequence)
			VALUES ($1, $2, 0, $3, $4)`,
			fmt.Sprintf("TESTFILLST%d", i+1), uid, fmt.Sprintf("F%d", i+1), i+1); err != nil {
			t.Fatalf("insert stop map: %v", err)
		}
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO bus_segment_time
		  (sub_route_uid, direction, from_stop_uid, to_stop_uid, secs, sample_count)
		VALUES ($1, 0, 'F1', 'F2', 200, 9)`, uid); err != nil {
		t.Fatalf("seed observed: %v", err)
	}

	if err := FillSegmentTimesFromDistance(ctx, pool); err != nil {
		t.Fatalf("FillSegmentTimesFromDistance: %v", err)
	}

	var secs, samples int
	if err := pool.QueryRow(ctx, `
		SELECT secs, sample_count FROM bus_segment_time
		WHERE sub_route_uid=$1 AND from_stop_uid='F2' AND to_stop_uid='F3'`, uid).
		Scan(&secs, &samples); err != nil {
		t.Fatalf("estimated hop F2->F3 missing: %v", err)
	}
	if samples != _segmentEstimatedSamples {
		t.Errorf("estimated sample_count = %d, want %d so readers can tell it apart", samples, _segmentEstimatedSamples)
	}
	// Same distance, same route pace: within 10% of the observed hop.
	if secs < 180 || secs > 220 {
		t.Errorf("estimated F2->F3 = %ds, want ~200s from the equal-distance observed hop", secs)
	}

	if err := pool.QueryRow(ctx, `
		SELECT secs, sample_count FROM bus_segment_time
		WHERE sub_route_uid=$1 AND from_stop_uid='F1' AND to_stop_uid='F2'`, uid).
		Scan(&secs, &samples); err != nil {
		t.Fatalf("observed hop lost: %v", err)
	}
	if secs != 200 || samples != 9 {
		t.Errorf("observed hop = (%d, %d), want (200, 9) untouched", secs, samples)
	}
}

func TestHistoryNativeDistanceFillPreservesDatabaseFailure(t *testing.T) {
	pool := segmentEtaTestPool(t)
	pool.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, cause := pool.Exec(ctx, "SELECT 1")
	core, logs := observer.New(zap.InfoLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(restore)
	err := FillSegmentTimesFromDistance(ctx, pool)
	if cause == nil || !errors.Is(err, cause) {
		t.Fatalf("database failure lost cause: %v / %v", err, cause)
	}
	if logs.FilterMessage("complete").Len() != 0 {
		t.Fatal("failed distance fill reported completion")
	}
}
