package main

import "testing"

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
