package dbgrants

import (
	"context"
	"os"
	"regexp"
	"slices"
	"testing"

	"github.com/jackc/pgx/v5"
)

var (
	_syncRulesFrom = regexp.MustCompile(`(?i)\bFROM\s+([a-z_]+)`)
	_pubTableLine  = regexp.MustCompile(`(?m)^ALTER PUBLICATION powersync ADD TABLE ONLY public\.([a-z_]+);$`)
	_grantLine     = regexp.MustCompile(`(?m)^GRANT SELECT ON TABLE public\.([a-z_]+) TO powersync_svc;$`)
)

// syncRuleTables returns the tables powersync/sync-rules.yaml reads, sorted.
func syncRuleTables(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile("../../../powersync/sync-rules.yaml")
	if err != nil {
		t.Fatalf("read sync rules: %v", err)
	}
	var tables []string
	for _, m := range _syncRulesFrom.FindAllStringSubmatch(string(raw), -1) {
		tables = append(tables, m[1])
	}
	slices.Sort(tables)
	return slices.Compact(tables)
}

// TestBaselinePublishesSyncRuleTables keeps the publication and the
// powersync_svc grants in the baseline equal to what the sync rules read, so
// neither can drift from the other.
func TestBaselinePublishesSyncRuleTables(t *testing.T) {
	want := syncRuleTables(t)
	raw, err := os.ReadFile("../../../migrations/baseline/0000-baseline.sql")
	if err != nil {
		t.Fatalf("read baseline: %v", err)
	}
	for name, rx := range map[string]*regexp.Regexp{"publication": _pubTableLine, "powersync_svc grants": _grantLine} {
		var got []string
		for _, m := range rx.FindAllStringSubmatch(string(raw), -1) {
			got = append(got, m[1])
		}
		slices.Sort(got)
		if !slices.Equal(got, want) {
			t.Errorf("baseline %s list %v, sync rules read %v", name, got, want)
		}
	}
}

// TestPublicationMatchesSyncRules checks the database the migrations ran on.
func TestPublicationMatchesSyncRules(t *testing.T) {
	pool := testPool(t)
	rows, err := pool.Query(context.Background(),
		`SELECT tablename FROM pg_publication_tables WHERE pubname = 'powersync' ORDER BY 1`)
	if err != nil {
		t.Fatalf("list publication tables: %v", err)
	}
	got, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatalf("scan publication tables: %v", err)
	}
	if len(got) == 0 {
		t.Skip("no powersync publication on this database")
	}
	if want := syncRuleTables(t); !slices.Equal(got, want) {
		t.Errorf("publication powersync lists %v, sync rules read %v", got, want)
	}
}
