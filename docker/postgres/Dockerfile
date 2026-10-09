# The one PostgreSQL image: the k3s cluster, CI and scripts/check-migrations.sh
# all run this file, so a migration is tested against the server it ships to.
# docker build -t bus-postgres docker/postgres
#
# Base: PostgreSQL 18.6 + PostGIS 3.6.4 (Debian trixie, pgdg apt already set up).
# The source database runs PostGIS 3.6.1; a patch-level gap restores cleanly
# and `ALTER EXTENSION postgis UPDATE` brings the catalog forward.
FROM postgis/postgis:18-3.6@sha256:60f6ad1d21ea86a67d47780b9a0d1e1d200500f62b19293fa834d0dea80b8677

# pgvector: the source database has `vector` installed (baseline creates it).
# pgBackRest: archive-push and backups run inside this image (ADR-0025).
# Versions come from the pgdg repo at build time; the build log's dpkg line is
# the record of what shipped.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-18-pgvector \
        pgbackrest \
    && rm -rf /var/lib/apt/lists/* \
    && dpkg -l postgresql-18-pgvector pgbackrest postgresql-18-postgis-3 | tail -n 3
