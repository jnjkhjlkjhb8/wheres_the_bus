package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildDatasetQuery(t *testing.T) {
	tests := []struct {
		name     string
		table    string
		partCol  string
		partVal  string
		wantSQL  string
		wantArgs []any
	}{
		{
			name:     "unpartitioned",
			table:    "thsr_station",
			wantSQL:  `SELECT COALESCE(jsonb_agg((to_jsonb(t) - ARRAY['fetched_at']::text[])), '[]'::jsonb) FROM raw_tdx.thsr_station t `,
			wantArgs: []any{},
		},
		{
			name:     "partitioned strips partition column and binds value",
			table:    "tra_dailytimetable",
			partCol:  "traindate",
			partVal:  "2026-07-05",
			wantSQL:  `SELECT COALESCE(jsonb_agg((to_jsonb(t) - ARRAY['fetched_at','traindate']::text[])), '[]'::jsonb) FROM raw_tdx.tra_dailytimetable t WHERE traindate = $1`,
			wantArgs: []any{"2026-07-05"},
		},
		{
			name:     "thsr_dailytimetable re-derives traindate string",
			table:    "thsr_dailytimetable",
			partCol:  "traindate",
			partVal:  "2026-07-05",
			wantSQL:  `SELECT COALESCE(jsonb_agg(((to_jsonb(t) - ARRAY['fetched_at','traindate']::text[]) || jsonb_build_object('traindate', to_char(t.traindate, 'YYYY-MM-DD')))), '[]'::jsonb) FROM raw_tdx.thsr_dailytimetable t WHERE traindate = $1`,
			wantArgs: []any{"2026-07-05"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotSQL, gotArgs := buildDatasetQuery(tt.table, tt.partCol, tt.partVal)
			if gotSQL != tt.wantSQL {
				t.Errorf("SQL mismatch\n got: %s\nwant: %s", gotSQL, tt.wantSQL)
			}
			if len(gotArgs) != len(tt.wantArgs) {
				t.Fatalf("args len = %d, want %d (%v)", len(gotArgs), len(tt.wantArgs), gotArgs)
			}
			for i := range tt.wantArgs {
				if gotArgs[i] != tt.wantArgs[i] {
					t.Errorf("args[%d] = %v, want %v", i, gotArgs[i], tt.wantArgs[i])
				}
			}
		})
	}
}

func TestCLIReportsUsageAndOperationalFailures(t *testing.T) {
	for _, test := range []struct {
		name    string
		args    []string
		dsn     string
		code    int
		message string
	}{
		{"help", []string{"-help"}, "", 0, "raw_tdx table name"},
		{"bad flag", []string{"-invalid"}, "", 2, "flag provided but not defined"},
		{"missing output", []string{"-table", "thsr_station"}, "", 2, "table and out"},
		{"missing table", []string{"-out", "fixture.json"}, "", 2, "table and out"},
		{"missing DSN", []string{"-table", "thsr_station", "-out", "fixture.json"}, "", 2, "DATABASE_URL not set"},
		{"invalid DSN", []string{"-table", "thsr_station", "-out", "fixture.json"}, "postgres://localhost:invalid/bus", 1, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			var stderr bytes.Buffer
			if code := runCLI(test.args, test.dsn, &stderr); code != test.code {
				t.Fatalf("code = %d, want %d", code, test.code)
			}
			if !strings.Contains(stderr.String(), test.message) {
				t.Fatalf("stderr = %q, want %q", stderr.String(), test.message)
			}
		})
	}
}

func TestExportReconstructsRawDatasetAndReportsIOErrors(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if os.Getenv("REQUIRE_DB_TESTS") == "1" {
			t.Fatal("DATABASE_URL required")
		}
		t.Skip("DATABASE_URL not set")
	}
	path := filepath.Join(t.TempDir(), "stations.json")
	var stderr bytes.Buffer
	if code := runCLI([]string{"-table", "thsr_station", "-out", path}, dsn, &stderr); code != 0 {
		t.Fatalf("export code = %d: %s", code, stderr.String())
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var records []map[string]any
	if err := json.Unmarshal(body, &records); err != nil {
		t.Fatalf("invalid fixture JSON: %v", err)
	}
	for _, record := range records {
		if _, found := record["fetched_at"]; found {
			t.Fatal("internal fetched_at leaked into fixture")
		}
	}
	if err := export(dsn, "quality_missing_table", "", "", path); err == nil {
		t.Fatal("missing relation succeeded")
	}
	if err := export(dsn, "thsr_station", "", "", filepath.Join(path, "invalid.json")); err == nil {
		t.Fatal("invalid output path succeeded")
	}
}
