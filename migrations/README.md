# Database Migrations

SQL migrations in this directory are the single source of truth for the PostgreSQL schema. Every main release applies the pending files automatically: the migrate image (`docker/migrate/Dockerfile`, which runs `scripts/migrate-all.sh`) runs as a Job before the rollout (ADR-0027). `scripts/apply-migration.sh` applies one file by hand. Agents cannot reach the database directly. See ADR-0010 for the full lifecycle decision.

`mysql/` holds the hand-applied DDL for the MySQL history archive (`services/shared/history`); it is not part of the PostgreSQL sequence.

## Bootstrap a new environment

A brand-new environment (disaster recovery or a from-scratch local database) is schema-bootstrapped in two steps:

```bash
# 1. Baseline: the production schema, squashed from every migration up to
#    2026-10-09 (see the file's header for how it was produced).
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migrations/baseline/0000-baseline.sql

# 2. Every dated file, in filename order, oldest first.
for f in migrations/*.sql; do
    [ -e "$f" ] || continue
    psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$f"
done
```

The baseline is not idempotent: apply it once, as a superuser, to an empty database. It creates the service roles without passwords; `scripts/k3s-db-credentials.sh passwords` sets them. `scripts/check-migrations.sh` proves this exact sequence — baseline then every dated file — replays cleanly on an empty database whenever Docker is available (see "CI replay" below).

The dated files the baseline replaced are in git history. The production `schema_migrations` ledger still lists them; `scripts/migrate-all.sh` only looks at files that exist, so those rows are inert.

Some dated files need a `-v target_schema=...` argument or a non-default `PGOPTIONS` — see "Schema targeting" below before scripting the loop above for a real apply.

## Naming

New DDL is a new dated file: `YYYY-MM-DD-short-name.sql`. `migrations/baseline/0000-baseline.sql` is a special, always-applied-first file — see "Bootstrap a new environment" above.

Do not edit a migration after it has been merged to main (the migrate Job applies it on the next release, and the ledger refuses a changed checksum); create the next dated file instead. A migration whose behavior is later found to be wrong or unsafe (e.g. it hardcoded `public` instead of being schema-aware) is superseded by a new file, not edited — mark the superseded file's first line `-- REPLAY: skip` (see "CI replay") so the replay harness stops re-applying it, and explain the supersession in its header comment.

## Ledger

Every environment's schema carries a `schema_migrations` table (created by the baseline): `filename` primary key, `sha256`, `applied_at`, `applied_by`. `scripts/apply-migration.sh` is the only writer — it applies one file with `psql`, then records `(filename, sha256sum(file), now(), $USER)`. Applying the same already-recorded filename again is a no-op if the checksum matches, and a hard failure if it doesn't (the file was edited after being applied — see "Naming" above for why that must never happen). This is the operator-facing counterpart to the CI replay gate: CI proves the *sequence* replays clean on a disposable database; the ledger proves *which files have actually been applied* to a real, persistent one.

```bash
DATABASE_URL=... scripts/apply-migration.sh migrations/<file>.sql
```

The k3s migrate Job (bus-infra's `k8s/migrate/job.yaml`, run by its `scripts/k3s-deploy.sh` before every rollout) applies pending files and records them in this ledger.

**Superuser-only files**: the k3s migrate Job runs as `bus_migrator`, which cannot create or drop roles or alter a publication it does not own. A file that needs that stops the Job with a hint naming `scripts/k3s-db-credentials.sh apply-superuser migrations/<file>.sql`, which applies it as `postgres` and records it so the next Job skips it. 
## CI replay

`scripts/check-migrations.sh` builds `docker/postgres` (the PostgreSQL 18 + PostGIS + pgvector image the cluster runs), applies the baseline plus every non-`-- REPLAY: skip` dated migration against an empty `public` schema, and fails (exit 1) on any error. It is wired into `make verify` (`migrations-check`) and requires Docker; without Docker it prints `SKIPPED` and exits 0 (CI always has Docker, so the gate is never silently skipped there).

```bash
scripts/check-migrations.sh
```

## Backward compatibility

The previous release keeps running while a migration applies, and again after an automatic rollback (ADR-0027). So every new file must leave the schema readable and writable by the code that is already deployed. `scripts/check-migration-lint.sh` (squawk, pinned version, config in `/.squawk.toml`) enforces this in CI:

- No dropping, renaming or retyping anything the running code reads, and no long locks on a live table (`CREATE INDEX CONCURRENTLY`, constraints `NOT VALID` then `VALIDATE`, no `NOT NULL` column without a default).
- A removal is two releases (expand/contract): first stop reading it, then drop it in a file named `*-contract.sql`. Only those files may `DROP TABLE`, `DROP COLUMN` or drop a `NOT NULL`. Renames and type changes are never a single statement; add the new column, backfill, switch readers, then contract the old one.
- `squawk-grandfathered.txt` exempts files that predate the gate. It is empty since the squash; never add to it.

```bash
scripts/check-migration-lint.sh            # lint new files
scripts/check-migration-lint.sh --self-test
```

## Destructive migrations

A file that only `TRUNCATE`s or `DELETE`s data (no compensating schema change) must live in its own dated file and:

- carry a header comment explaining why the action is safe and, where feasible, a row-count preview query an operator can run first (`SELECT count(*) FROM <table> WHERE ...`);
- have its preview query run against the cluster database before the change is merged, since merging applies it;
- be marked `-- REPLAY: skip` on its first line once applied, so `scripts/check-migrations.sh` does not re-run a one-shot cleanup against every fresh environment forever (`scripts/apply-migration.sh`'s ledger is the operator-side guard against an accidental second real apply).

## Apply

```bash
psql "$DATABASE_URL" -f migrations/<file>.sql
```

`DATABASE_URL` targets the `public` schema; there is one environment (ADR-0025).

### Recommended flags

Always run with `-X` (skip `~/.psqlrc`, so a local psql customization can't
silently change how a migration applies) and `-v ON_ERROR_STOP=1` (a
mid-file statement failure aborts instead of continuing past it):

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migrations/<file>.sql
```

Some migration files (any using `pg_index`/`pg_class` catalog lookups
combined with psql's `\gset`/`\if`) also read psql variables passed
with `-v`. Check the file's header comment for supported variables before
applying.

### Schema targeting

When applying to a non-default schema, set it via `PGOPTIONS`, not by
editing the SQL file:

```bash
PGOPTIONS="-c search_path=$PG_SCHEMA" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migrations/<file>.sql
```

A dated migration should assert `current_schema()` resolves to a
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

Write conventions for ingestion SQL are documented in `docs/storage.md`.
