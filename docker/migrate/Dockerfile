# The per-release migration runner (ADR-0027): migrations/ plus
# scripts/migrate-all.sh on the same PostgreSQL 18 base the cluster runs, so
# psql matches the server.
# docker build -f docker/migrate/Dockerfile -t bus-migrate .
FROM postgis/postgis:18-3.6@sha256:60f6ad1d21ea86a67d47780b9a0d1e1d200500f62b19293fa834d0dea80b8677
COPY migrations/ /migrations/
COPY scripts/migrate-all.sh /usr/local/bin/migrate-all
USER 999:999
ENTRYPOINT ["/usr/local/bin/migrate-all", "/migrations"]
