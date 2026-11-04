package mrtsync

import (
	"os"
	"regexp"
	"slices"
	"strings"
	"testing"
)

var _alias = regexp.MustCompile(`(?i)\bAS\s+[a-z_]+`)

var _columnLine = regexp.MustCompile(`(?m)^\s+([a-z_]+) ([a-z ]+?)(?: CONSTRAINT \S+)?(?: DEFAULT \S+)?(?: NOT NULL)?(?: PRIMARY KEY)?,?$`)

// tableColumns maps column name to type for one CREATE TABLE in sql.
func tableColumns(t *testing.T, sql, create, name string) map[string]string {
	t.Helper()
	start := strings.Index(sql, create+name+" (")
	if start < 0 {
		t.Fatalf("%s not found", name)
	}
	body := sql[start : start+strings.Index(sql[start:], "\n);")]
	cols := map[string]string{}
	for _, m := range _columnLine.FindAllStringSubmatch(body, -1) {
		if m[1] != "constraint" {
			cols[m[1]] = m[2]
		}
	}
	return cols
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// The copy must hold every bus column the sync rules read, with the same type,
// and nothing the sync code does not write.
func TestSchemaMatchesBusAndSyncRules(t *testing.T) {
	baseline := readFile(t, "../../../../migrations/baseline/0000-baseline.sql")
	rules := readFile(t, "../../../../powersync/sync-rules.yaml")
	for _, tbl := range _tables {
		copyCols := tableColumns(t, schemaSQL, "CREATE TABLE IF NOT EXISTS ", tbl.name)
		busCols := tableColumns(t, baseline, "CREATE TABLE public.", tbl.name)

		got := make([]string, 0, len(copyCols))
		for c := range copyCols {
			got = append(got, c)
		}
		want := tbl.columns()
		slices.Sort(got)
		slices.Sort(want)
		if !slices.Equal(got, want) {
			t.Errorf("%s: schema.sql columns %v, sync writes %v", tbl.name, got, want)
		}
		for c, typ := range copyCols {
			if busCols[c] != typ {
				t.Errorf("%s.%s: copy type %q, bus type %q", tbl.name, c, typ, busCols[c])
			}
		}

		end := strings.Index(rules, "FROM "+tbl.name)
		if end < 0 {
			t.Fatalf("sync rules do not read %s", tbl.name)
		}
		// Output aliases (`... AS id`) name nothing in the table.
		selectList := _alias.ReplaceAllString(rules[strings.LastIndex(rules[:end], "SELECT"):end], "")
		for c := range busCols {
			if regexp.MustCompile(`\b`+c+`\b`).MatchString(selectList) && copyCols[c] == "" {
				t.Errorf("sync rules read %s.%s, which the copy does not hold", tbl.name, c)
			}
		}
	}
}
