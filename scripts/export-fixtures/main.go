package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	table := flag.String("table", "", "raw_tdx table name")
	partCol := flag.String("partcol", "", "partition column (city|system|traindate), empty for unpartitioned")
	part := flag.String("part", "", "partition value")
	out := flag.String("out", "", "output JSON file")
	flag.Parse()
	if *table == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "table and out are required")
		os.Exit(2)
	}

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		fmt.Fprintln(os.Stderr, "DATABASE_URL not set")
		os.Exit(2)
	}
	if err := export(dsn, *table, *partCol, *part, *out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func export(dsn, table, partCol, part, out string) error {
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		return err
	}
	defer pool.Close()

	body, err := datasetJSON(context.Background(), pool, table, partCol, part)
	if err != nil {
		return err
	}
	if err := os.WriteFile(out, body, 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %d bytes to %s\n", len(body), out)
	return nil
}

func datasetJSON(ctx context.Context, pool *pgxpool.Pool, table, partCol, partVal string) ([]byte, error) {
	q, args := buildDatasetQuery(table, partCol, partVal)
	var body []byte
	if err := pool.QueryRow(ctx, q, args...).Scan(&body); err != nil {
		return nil, err
	}
	return body, nil
}

// buildDatasetQuery builds the reconstruction SQL and its args. partCol is
// interpolated into the query, so callers must pass only trusted column names.
func buildDatasetQuery(table, partCol, partVal string) (string, []any) {
	strip := "ARRAY['fetched_at']::text[]"
	if partCol != "" {
		strip = fmt.Sprintf("ARRAY['fetched_at','%s']::text[]", partCol)
	}
	elem := fmt.Sprintf("(to_jsonb(t) - %s)", strip)
	if table == "thsr_dailytimetable" {
		// Re-derive traindate as a YYYY-MM-DD string; the landing column is
		// timestamptz but the transform historically decoded a date-only string.
		elem = fmt.Sprintf("(%s || jsonb_build_object('traindate', to_char(t.traindate, 'YYYY-MM-DD')))", elem)
	}
	where := ""
	args := []any{}
	if partCol != "" {
		where = fmt.Sprintf("WHERE %s = $1", partCol)
		args = append(args, partVal)
	}
	q := fmt.Sprintf(
		`SELECT COALESCE(jsonb_agg(%s), '[]'::jsonb) FROM raw_tdx.%s t %s`,
		elem, table, where)
	return q, args
}
