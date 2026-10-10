// Package dbgrants checks the per-service PostgreSQL grants from
// migrations/2026-10-07-service-roles-k3s.sql (ADR-0026) against a database
// the migrations have been applied to. It has no non-test code.
package dbgrants

import (
	"context"
	"errors"
	"os"
	"slices"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	_serviceRoles = []string{"api_svc", "realtime_svc", "rider_svc", "pipeline_svc"}
	_riderTables  = []string{
		"firebase_device", "firebase_route_subscription", "firebase_arrival_reminder",
		"feedback_thread", "feedback_message",
	}
)

type table struct{ schema, name string }

func (t table) String() string { return t.schema + "." + t.name }

func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required for DB integration tests")
		}
		t.Skip("DATABASE_URL not set; skipping grant tests")
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	var missing int
	if err := pool.QueryRow(context.Background(),
		`SELECT count(*) FROM unnest($1::text[]) AS r WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)`,
		_serviceRoles).Scan(&missing); err != nil {
		t.Fatalf("probe roles: %v", err)
	}
	if missing > 0 {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("service roles missing; apply migrations/2026-10-07-service-roles-k3s.sql")
		}
		t.Skip("service roles not provisioned; skipping grant tests")
	}
	return pool
}

func appTables(t *testing.T, pool *pgxpool.Pool) []table {
	t.Helper()
	rows, err := pool.Query(context.Background(), `
		SELECT schemaname, tablename FROM pg_tables
		WHERE schemaname IN ('public', 'raw_tdx')
		  AND NOT (schemaname = 'public' AND tablename IN ('schema_migrations', 'spatial_ref_sys'))
		ORDER BY 1, 2`)
	if err != nil {
		t.Fatalf("list tables: %v", err)
	}
	tables, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (table, error) {
		var tb table
		err := r.Scan(&tb.schema, &tb.name)
		return tb, err
	})
	if err != nil {
		t.Fatalf("scan tables: %v", err)
	}
	if len(tables) == 0 {
		t.Fatal("no application tables found; were the migrations applied?")
	}
	return tables
}

func hasPrivilege(t *testing.T, pool *pgxpool.Pool, role string, tb table, privilege string) bool {
	t.Helper()
	var ok bool
	if err := pool.QueryRow(context.Background(),
		`SELECT has_table_privilege($1, format('%I.%I', $2::text, $3::text), $4)`,
		role, tb.schema, tb.name, privilege).Scan(&ok); err != nil {
		t.Fatalf("has_table_privilege(%s, %s, %s): %v", role, tb, privilege, err)
	}
	return ok
}

// TestEveryTableHasExactlyOneWriter is the coverage half: a migration that
// adds a table without granting it to its owning service fails here.
func TestEveryTableHasExactlyOneWriter(t *testing.T) {
	pool := testPool(t)
	for _, tb := range appTables(t, pool) {
		var writers []string
		for _, role := range _serviceRoles {
			if hasPrivilege(t, pool, role, tb, "INSERT") {
				writers = append(writers, role)
			}
		}
		if len(writers) != 1 {
			t.Errorf("%s: want exactly one writing service, got %v", tb, writers)
		}
	}
}

func TestOwnershipBoundaries(t *testing.T) {
	pool := testPool(t)
	for _, tb := range appTables(t, pool) {
		rider := tb.schema == "public" && slices.Contains(_riderTables, tb.name)
		for _, role := range _serviceRoles {
			canRead := hasPrivilege(t, pool, role, tb, "SELECT")
			canWrite := hasPrivilege(t, pool, role, tb, "INSERT") ||
				hasPrivilege(t, pool, role, tb, "UPDATE") ||
				hasPrivilege(t, pool, role, tb, "DELETE") ||
				hasPrivilege(t, pool, role, tb, "TRUNCATE")

			switch {
			case role == "api_svc" && canWrite:
				t.Errorf("%s: api_svc must never write", tb)
			case tb.schema == "raw_tdx" && role != "pipeline_svc" && (canRead || canWrite):
				t.Errorf("%s: only pipeline_svc may touch raw_tdx, %s can", tb, role)
			case rider && role != "rider_svc" && (canRead || canWrite):
				t.Errorf("%s: only rider_svc may touch rider state, %s can", tb, role)
			case rider && role == "rider_svc" && !canWrite:
				t.Errorf("%s: rider_svc must be able to write its own table", tb)
			case !rider && tb.schema == "public" && !canRead:
				t.Errorf("%s: %s must be able to read the catalog", tb, role)
			}
		}
	}
}

// TestDeniedWritesFail proves the grants are enforced by the server, not just
// reported by has_table_privilege: each statement runs under SET ROLE and must
// fail with insufficient_privilege (42501).
func TestDeniedWritesFail(t *testing.T) {
	pool := testPool(t)
	tests := []struct {
		role string
		sql  string
	}{
		{"api_svc", `DELETE FROM public.bus_stations WHERE false`},
		{"realtime_svc", `DELETE FROM public.search_vector WHERE false`},
		{"rider_svc", `DELETE FROM public.bus_stations WHERE false`},
		{"pipeline_svc", `SELECT 1 FROM public.firebase_device LIMIT 1`},
		{"api_svc", `SELECT 1 FROM raw_tdx.landing_state LIMIT 1`},
		{"rider_svc", `TRUNCATE raw_tdx.landing_state`},
	}
	for _, tt := range tests {
		t.Run(tt.role+": "+tt.sql, func(t *testing.T) {
			ctx := context.Background()
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatalf("begin: %v", err)
			}
			defer func() { _ = tx.Rollback(ctx) }()

			if _, err := tx.Exec(ctx, "SET LOCAL ROLE "+pgx.Identifier{tt.role}.Sanitize()); err != nil {
				t.Fatalf("set role: %v", err)
			}
			_, err = tx.Exec(ctx, tt.sql)
			var pgErr *pgconn.PgError
			if !errors.As(err, &pgErr) || pgErr.Code != "42501" {
				t.Fatalf("want insufficient_privilege (42501), got %v", err)
			}
		})
	}
}

// TestServiceWritesSucceed covers the writes a service makes outside its own
// tables: realtime inserts prediction rows and route alerts that pipeline and
// rider later process.
func TestServiceWritesSucceed(t *testing.T) {
	pool := testPool(t)
	tests := []struct {
		role string
		sql  string
	}{
		{"realtime_svc", `INSERT INTO public.bus_eta_prediction_error
			(sub_route_uid, direction, stop_uid, source, predicted_at, predicted_seconds)
			VALUES ('grant-test', 0, 'grant-test', 'tdx', now(), 1)`},
		{"realtime_svc", `INSERT INTO public.route_alert_outbox (dedupe_key, route_type, route_key, body)
			VALUES ('grant-test', 'bus', 'grant-test', '{}')`},
		{"pipeline_svc", `UPDATE public.bus_eta_prediction_error SET actual_seconds = 1 WHERE false`},
		{"pipeline_svc", `DELETE FROM public.bus_eta_prediction_error WHERE false`},
	}
	for _, tt := range tests {
		t.Run(tt.role+": "+tt.sql, func(t *testing.T) {
			ctx := context.Background()
			tx, err := pool.Begin(ctx)
			if err != nil {
				t.Fatalf("begin: %v", err)
			}
			defer func() { _ = tx.Rollback(ctx) }()

			if _, err := tx.Exec(ctx, "SET LOCAL ROLE "+pgx.Identifier{tt.role}.Sanitize()); err != nil {
				t.Fatalf("set role: %v", err)
			}
			if _, err := tx.Exec(ctx, tt.sql); err != nil {
				t.Fatalf("want success, got %v", err)
			}
		})
	}
}
