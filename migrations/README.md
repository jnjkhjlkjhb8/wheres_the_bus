# Database Migrations

SQL migrations in this directory are the single source of truth for the PostgreSQL schema. Every main release applies the pending files automatically: the migrate image (`docker/migrate/Dockerfile`, which runs `scripts/migrate-all.sh`) runs as a Job before the rollout (ADR-0027). Agents cannot reach the database directly. See ADR-0010 for the full lifecycle decision.

This file is how to write a migration. Bootstrapping a database, the ledger, and applying a file by hand are operator steps in bus-infra's `migrations.md`.

`mysql/` holds the hand-applied DDL for the MySQL history archive (`services/shared/history`); it is not part of the PostgreSQL sequence.

## Naming

New DDL is a new dated file: `YYYY-MM-DD-short-name.sql`. `baseline/0000-baseline.sql` is the production schema squashed up to 2026-10-09; a fresh database applies it first, then every dated file in filename order.

Do not edit a migration after it has been merged to main (the migrate Job applies it on the next release, and the `schema_migrations` ledger refuses a changed checksum); create the next dated file instead. A migration whose behavior is later found to be wrong or unsafe (e.g. it hardcoded `public` instead of being schema-aware) is superseded by a new file, not edited — mark the superseded file's first line `-- REPLAY: skip` (see "CI replay") so the replay harness stops re-applying it, and explain the supersession in its header comment.

The migrate Job runs as `bus_migrator`, which cannot create or drop roles or alter a publication it does not own. A file that needs that is applied by the operator as `postgres`; say so in its header.

A dated migration should assert `current_schema()` resolves to a real schema before making any change, so applying without the intended `search_path` fails fast instead of silently landing in the wrong schema. Files using `CREATE`/`DROP INDEX CONCURRENTLY` are written for psql's default autocommit-per-statement behavior.

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
- be marked `-- REPLAY: skip` on its first line once applied, so `scripts/check-migrations.sh` does not re-run a one-shot cleanup against every fresh environment forever (the ledger is the operator-side guard against an accidental second real apply).

Write conventions for ingestion SQL are documented in `docs/storage.md`.
