-- Metro same-line adjacency graph, the ride graph a metro alight-reminder
-- session walks (ADR-0015). Loaded from raw_tdx.metro_s2straveltime (the same
-- landed S2STravelTime segments loadMrtTrtcTravelTime reads for OD times), TRTC
-- only. Segments only — the LineTransfer feed is intentionally excluded: one
-- train never crosses an interchange, so transfer edges must not join two lines
-- into one component. The loader stores both directions of every segment, so the
-- router's board→terminal BFS treats the ride graph as undirected within a line
-- with a plain directed-edge lookup. line_id is the S2S element's top-level
-- lineid. Idempotent (CREATE ... IF NOT EXISTS); the loader refreshes rows in
-- place via an ON CONFLICT upsert keyed by (system, from_station_id,
-- to_station_id).
CREATE TABLE IF NOT EXISTS mrt_adjacency (
    system          text        NOT NULL,
    line_id         text        NOT NULL,
    from_station_id text        NOT NULL,
    to_station_id   text        NOT NULL,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (system, from_station_id, to_station_id)
);

-- BFS reads every edge for a system; the primary key already leads with system,
-- so no additional index is needed.
