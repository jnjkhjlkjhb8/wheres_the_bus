package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	os.Exit(runCLI(os.Args[1:], os.Getenv("DATABASE_URL"), os.Stderr))
}

type exportOptions struct{ table, partCol, part, out string }

func parseExportOptions(args []string, stderr io.Writer) (exportOptions, error) {
	flags := flag.NewFlagSet("export-fixtures", flag.ContinueOnError)
	flags.SetOutput(stderr)
	var options exportOptions
	flags.StringVar(&options.table, "table", "", "raw_tdx table name")
	flags.StringVar(&options.partCol, "partcol", "", "partition column (city|system|traindate), empty for unpartitioned")
	flags.StringVar(&options.part, "part", "", "partition value")
	flags.StringVar(&options.out, "out", "", "output JSON file")
	err := flags.Parse(args)
	return options, err
}

func runCLI(args []string, dsn string, stderr io.Writer) int {
	options, err := parseExportOptions(args, stderr)
	if errors.Is(err, flag.ErrHelp) {
		return 0
	}
	if err != nil {
		return 2
	}
	if err := validateExportOptions(options, dsn); err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		return 2
	}
	return executeExport(options, dsn, stderr)
}

func validateExportOptions(options exportOptions, dsn string) error {
	if options.table == "" || options.out == "" {
		return errors.New("table and out are required")
	}
	if dsn == "" {
		return errors.New("DATABASE_URL not set")
	}
	return nil
}

func executeExport(options exportOptions, dsn string, stderr io.Writer) int {
	if err := export(dsn, options.table, options.partCol, options.part, options.out); err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
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
