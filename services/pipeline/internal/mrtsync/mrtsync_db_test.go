package mrtsync

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
)

// scratchDB creates a throwaway database on the DATABASE_URL server and
// returns its URL and a connection to it. It needs CREATEDB, which CI's
// superuser has.
func scratchDB(t *testing.T, admin *pgx.Conn, dsn, name string) (string, *pgx.Conn) {
	t.Helper()
	ctx := context.Background()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Skipf("cannot create a scratch database: %v", err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)") })
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + name
	conn, err := pgx.Connect(ctx, u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close(context.Background()) })
	return u.String(), conn
}

func exec(t *testing.T, conn *pgx.Conn, sql string) {
	t.Helper()
	if _, err := conn.Exec(context.Background(), sql); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

func TestSyncCopiesOnlyChanges(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = admin.Close(ctx) }()
	suffix := fmt.Sprint(os.Getpid())
	_, _ = admin.Exec(ctx, "CREATE ROLE powersync_svc")

	_, src := scratchDB(t, admin, dsn, "mrtsync_src_"+suffix)
	exec(t, src, `CREATE TABLE mrt_schedule (system text, station_id text, lineid text, destinationstaionid text,
		serviceday smallint, firsttraintime text, lasttraintime text, updated_at timestamptz DEFAULT now())`)
	exec(t, src, `CREATE TABLE mrt_journey_matrix (id text, from_station_id text, to_station_id text, system text,
		fare_nt integer, half_fare_nt integer, travel_time_min integer, updated_at timestamptz DEFAULT now())`)
	exec(t, src, `INSERT INTO mrt_schedule VALUES
		('TRTC','BL12','BL','BL01',1,'06:00','00:00'), ('TRTC','BL12','BL','BL23',1,'06:01','00:01')`)
	exec(t, src, `INSERT INTO mrt_journey_matrix VALUES ('a','BL12','BL13','TRTC',20,10,2), ('b','BL12','R10','TRTC',25,12,8)`)
	dstDSN, dst := scratchDB(t, admin, dsn, "mrtsync_dst_"+suffix)

	if err := Run(ctx, src, dstDSN); err != nil {
		t.Fatalf("first sync: %v", err)
	}
	if err := Run(ctx, src, "postgres://nobody@127.0.0.1:1/x?sslmode=disable&connect_timeout=1"); err == nil {
		t.Fatal("run against an unreachable powersync-db succeeded")
	}
	var published int
	if err := dst.QueryRow(ctx, `SELECT count(*) FROM pg_publication_tables WHERE pubname = 'powersync'`).Scan(&published); err != nil || published != 2 {
		t.Fatalf("powersync publication tables = %d, %v", published, err)
	}
	if _, err := Sync(ctx, src, dst); err != nil {
		t.Fatalf("re-applying the schema: %v", err)
	}

	// One changed row, one deleted row, one untouched row per table.
	exec(t, src, `UPDATE mrt_schedule SET lasttraintime = '00:30' WHERE destinationstaionid = 'BL23'`)
	exec(t, src, `DELETE FROM mrt_journey_matrix WHERE id = 'b'`)
	stats, err := Sync(ctx, src, dst)
	if err != nil {
		t.Fatalf("second sync: %v", err)
	}
	want := []Stats{
		{Table: "mrt_schedule", Source: 2, Upserted: 1, Deleted: 0},
		{Table: "mrt_journey_matrix", Source: 1, Upserted: 0, Deleted: 1},
	}
	if fmt.Sprint(stats) != fmt.Sprint(want) {
		t.Fatalf("stats = %v, want %v", stats, want)
	}
	var last string
	if err := dst.QueryRow(ctx, `SELECT lasttraintime FROM mrt_schedule WHERE destinationstaionid = 'BL23'`).Scan(&last); err != nil || last != "00:30" {
		t.Fatalf("updated row = %q, %v", last, err)
	}

	// A live table that drifted from schema.sql stops the sync before any write.
	exec(t, dst, `ALTER TABLE mrt_journey_matrix ADD COLUMN extra text`)
	if _, err := Sync(ctx, src, dst); err == nil {
		t.Fatal("sync into a drifted copy succeeded; it must refuse")
	}
	exec(t, dst, `ALTER TABLE mrt_journey_matrix DROP COLUMN extra`)

	exec(t, src, `DELETE FROM mrt_journey_matrix`)
	if _, err := Sync(ctx, src, dst); err == nil {
		t.Fatal("sync from an empty source table succeeded; it must refuse")
	}
	var n int
	if err := dst.QueryRow(ctx, `SELECT count(*) FROM mrt_journey_matrix`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("copy rows after refused sync = %d, %v", n, err)
	}
}
