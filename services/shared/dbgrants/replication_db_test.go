package dbgrants

import (
	"context"
	"testing"
)

// powersync_svc holds REPLICATION, which logical decoding checks instead of
// table grants. What keeps it on the two mrt_* tables is that the only output
// plugin left is pgoutput, which reads through a publication, and that it
// cannot create a publication of its own.
func TestPowersyncReplicationStaysOnPublication(t *testing.T) {
	pool := testPool(t)
	ctx := context.Background()

	var canCreate bool
	if err := pool.QueryRow(ctx,
		`SELECT has_database_privilege('powersync_svc', current_database(), 'CREATE')`).Scan(&canCreate); err != nil {
		t.Fatalf("probe CREATE: %v", err)
	}
	if canCreate {
		t.Error("powersync_svc can CREATE in this database, so it could publish the rider tables itself")
	}

	var super bool
	if err := pool.QueryRow(ctx, `SELECT rolsuper FROM pg_roles WHERE rolname = current_user`).Scan(&super); err != nil {
		t.Fatalf("probe superuser: %v", err)
	}
	if !super {
		t.Skip("reading the library directory needs a superuser")
	}
	for plugin, want := range map[string]bool{"pgoutput": true, "test_decoding": false} {
		var present bool
		if err := pool.QueryRow(ctx, `
			SELECT (pg_stat_file(setting || '/' || $1 || '.so', true)).size IS NOT NULL
			FROM pg_config WHERE name = 'PKGLIBDIR'`, plugin).Scan(&present); err != nil {
			t.Fatalf("stat %s: %v", plugin, err)
		}
		if present != want {
			t.Errorf("output plugin %s present = %v, want %v (docker/postgres/Dockerfile)", plugin, present, want)
		}
	}
}
