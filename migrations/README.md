# Database Migrations

SQL migrations in this directory are the single source of truth for schema changes and are **hand-applied** — there is no migration runner. The user applies each file to Azure with `psql` (or `scripts/apply-migration.sh`, see below); agents cannot reach the database directly. See ADR-0010 for the full lifecycle decision.

## Bootstrap a new environment

A brand-new environment (a new staging replica, disaster recovery, or a from-scratch local database) is schema-bootstrapped in two steps:

```bash
# 1. Baseline: reconstructed pre-migrations-history schema (extensions, the
#    staging schema, core tables that predate this directory — see the
#    file's own header for how each piece was derived).
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migrations/baseline/0000-baseline.sql

# 2. Every dated file, in filename order, oldest first.
for f in migrations/*.sql; do
    psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$f"
done
```

The baseline is idempotent (`IF NOT EXISTS` throughout), so running it against an environment that already has these objects (i.e. the real Azure database, where they were created out-of-band before `migrations/` existed) is a safe no-op. `scripts/check-migrations.sh` proves this exact sequence — baseline then every dated file — replays cleanly on an empty database, for both `public` and `staging`, whenever Docker is available (see "CI replay" below).

Some dated files need a `-v target_schema=...` argument or a non-default `PGOPTIONS` — see "Schema targeting" below before scripting the loop above for a real apply.

## Naming

New DDL is a new dated file: `YYYY-MM-DD-short-name.sql` (e.g. `2026-07-04-raw-tdx-schema.sql`). Older files use a legacy `NNNN_name.sql` numeric prefix; do not add new files in that style. `migrations/baseline/0000-baseline.sql` is a special, always-applied-first file — see "Bootstrap a new environment" above.

Do not edit a migration after it has been applied to staging or production; create the next dated file instead. A migration whose behavior is later found to be wrong or unsafe (e.g. it hardcoded `public` instead of being schema-aware) is superseded by a new file, not edited — mark the superseded file's first line `-- REPLAY: skip` (see "CI replay") so the replay harness stops re-applying it, and explain the supersession in its header comment.

## Ledger

Every environment's schema carries a `schema_migrations` table (`migrations/2026-07-17-schema-migrations-ledger.sql`): `filename` primary key, `sha256`, `applied_at`, `applied_by`. `scripts/apply-migration.sh` is the only writer — it applies one file with `psql`, then records `(filename, sha256sum(file), now(), $USER)`. Applying the same already-recorded filename again is a no-op if the checksum matches, and a hard failure if it doesn't (the file was edited after being applied — see "Naming" above for why that must never happen). This is the operator-facing counterpart to the CI replay gate: CI proves the *sequence* replays clean on a disposable database; the ledger proves *which files have actually been applied* to a real, persistent one.

```bash
DATABASE_URL=... scripts/apply-migration.sh migrations/<file>.sql
# staging:
PGOPTIONS="-c search_path=staging" DATABASE_URL=... scripts/apply-migration.sh migrations/<file>.sql
```

`scripts/deploy-transaction.sh` reads this ledger as a pre-deploy gate: a dated file that is missing from the ledger (unless marked `-- REPLAY: skip`) or whose recorded checksum no longer matches the file blocks the deploy. It never applies SQL — applying stays a manual operator step.

**Backfill**: a file that was applied to the real database *before* the ledger existed has no row, so the deploy gate will flag it. Record it without re-running its SQL (unlike `apply-migration.sh`, which would re-apply the file):

```bash
name=<file>.sql; sum=$(sha256sum "migrations/$name" | awk '{print $1}')
# staging: prefix with PGOPTIONS="-c search_path=staging"
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
    -c "INSERT INTO schema_migrations (filename, sha256, applied_by) VALUES ('$name', '$sum', '${USER}-backfill') ON CONFLICT (filename) DO NOTHING;"
```

## CI replay

`scripts/check-migrations.sh` builds `docker/postgres` (the PostgreSQL 18 + PostGIS + pgvector image the cluster runs), applies the baseline plus every non-`-- REPLAY: skip` dated migration against an empty `public` schema, and fails (exit 1) on any error. The staging round was dropped with staging itself (ADR-0025). It is wired into `make verify` (`migrations-check`) and requires Docker; without Docker it prints `SKIPPED` and exits 0 (CI always has Docker, so the gate is never silently skipped there).

```bash
scripts/check-migrations.sh
```

## Backward compatibility

The previous release keeps running while a migration applies, and again after an automatic rollback (ADR-0027). So every new file must leave the schema readable and writable by the code that is already deployed. `scripts/check-migration-lint.sh` (squawk, pinned version, config in `/.squawk.toml`) enforces this in CI:

- No dropping, renaming or retyping anything the running code reads, and no long locks on a live table (`CREATE INDEX CONCURRENTLY`, constraints `NOT VALID` then `VALIDATE`, no `NOT NULL` column without a default).
- A removal is two releases (expand/contract): first stop reading it, then drop it in a file named `*-contract.sql`. Only those files may `DROP TABLE`, `DROP COLUMN` or drop a `NOT NULL`. Renames and type changes are never a single statement; add the new column, backfill, switch readers, then contract the old one.
- Files listed in `squawk-grandfathered.txt` predate the gate and are exempt. Never add to that list.

```bash
scripts/check-migration-lint.sh            # lint new files
scripts/check-migration-lint.sh --self-test
```

## Destructive migrations

A file that only `TRUNCATE`s or `DELETE`s data (no compensating schema change) must live in its own dated file and:

- carry a header comment explaining why the action is safe and, where feasible, a row-count preview query an operator can run first (`SELECT count(*) FROM <table> WHERE ...`);
- be applied to staging first, and confirmed there before the same file is applied to production;
- be marked `-- REPLAY: skip` on its first line once applied, so `scripts/check-migrations.sh` does not re-run a one-shot cleanup against every fresh environment forever (`scripts/apply-migration.sh`'s ledger is the operator-side guard against an accidental second real apply — see 2026-07-07-truncate-bus-eta-training-data.sql for the pattern).

## Apply

```bash
psql "$DATABASE_URL" -f migrations/<file>.sql
```

For staging, `DATABASE_URL` points at the Azure instance with `PG_SCHEMA=staging`; for prod it targets the `public` schema (see `AGENTS.md`).

### Recommended flags

Always run with `-X` (skip `~/.psqlrc`, so a local psql customization can't
silently change how a migration applies) and `-v ON_ERROR_STOP=1` (a
mid-file statement failure aborts instead of continuing past it):

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migrations/<file>.sql
```

Some migration files (any using `pg_index`/`pg_class` catalog lookups
combined with psql's `\gset`/`\if`, e.g.
`2026-07-16-search-vector-hnsw-dedupe.sql`) also read psql variables passed
with `-v`. Check the file's header comment for supported variables before
applying.

### Schema targeting

When applying to a non-default schema (e.g. staging's `PG_SCHEMA=staging`),
set the schema via `PGOPTIONS`, not by editing the SQL file:

```bash
PGOPTIONS="-c search_path=$PG_SCHEMA" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migrations/<file>.sql
```

Migrations added after 2026-07-16 assert `current_schema()` resolves to a
real schema before making any change, so applying without a `search_path`
that puts the intended schema first fails fast with a clear error instead
of silently landing in the wrong schema (or in `public` by accident).

### `CREATE`/`DROP INDEX CONCURRENTLY`

Files that use `CONCURRENTLY` (search for it in the file before applying)
must run outside any wrapping transaction — do not put `\set AUTOCOMMIT
off` in `~/.psqlrc`, wrap the `psql -f` call in `BEGIN`/`COMMIT`, or paste
the file's contents into a client that batches statements into one
transaction. Applying the file directly with the command above is safe;
these files are written assuming psql's default autocommit-per-statement
behavior.

## Example: the raw_tdx reconciliation migration

`2026-07-04-raw-tdx-schema.sql` provisions the shared `raw_tdx` landing schema used by the two-stage ingestion flow (ADR-0005): the ingestor lands verbatim TDX payloads there at 03:00, and every environment's loader transforms them into its own `PG_SCHEMA` at 03:30. It is the current template for a new dated migration.

Write conventions for ingestion SQL are documented in `docs/storage.md`.
