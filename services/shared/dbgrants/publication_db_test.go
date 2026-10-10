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
	_syncRulesFrom   = regexp.MustCompile(`(?i)\bFROM\s+([a-z_]+)`)
	_publicTableList = regexp.MustCompile(`public\.([a-z_]+)`)
	_finishPubLine   = regexp.MustCompile(`(?m)^.*(?:SET TABLE|FOR TABLE|GRANT SELECT ON) public\..*$`)
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

// TestFinishPublishesSyncRuleTables keeps the publication and the powersync_svc
// grants that scripts/k3s-db-credentials.sh finish sets up equal to what the
// sync rules read, so neither can drift from the other.
func TestFinishPublishesSyncRuleTables(t *testing.T) {
	want := syncRuleTables(t)
	raw, err := os.ReadFile("../../../scripts/k3s-db-credentials.sh")
	if err != nil {
		t.Fatalf("read credentials script: %v", err)
	}
	lines := _finishPubLine.FindAllString(string(raw), -1)
	if len(lines) != 3 {
		t.Fatalf("want the GRANT, SET TABLE and FOR TABLE lines in finish, found %d: %q", len(lines), lines)
	}
	for _, line := range lines {
		var got []string
		for _, m := range _publicTableList.FindAllStringSubmatch(line, -1) {
			got = append(got, m[1])
		}
		slices.Sort(got)
		if !slices.Equal(got, want) {
			t.Errorf("%q lists %v, sync rules read %v", line, got, want)
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
