-- 2026-07-30-metro-route-length-numeric.sql
-- Hand-applied to Azure: psql "$DATABASE_URL" -f migrations/2026-07-30-metro-route-length-numeric.sql
--
-- raw_tdx.metro_route.routelength was created integer, which lands TRTC and
-- fails everywhere else:
--
--   /v2/Rail/Metro/Route/KRTC  ERROR: invalid input syntax for type integer: "13.12"
--   /v2/Rail/Metro/Route/TYMC  ERROR: invalid input syntax for type integer: "51.76"
--   /v2/Rail/Metro/Route/TMRT  ERROR: invalid input syntax for type integer: "16.7"
--
-- RouteLength is route kilometres, so a fractional value is the normal case.
-- TRTC alone reports 0.0 on every route, which is why the integer column held
-- until the landing set widened past Taipei.
--
-- Only this column is affected: across all five landed systems the other numeric
-- Route fields (TravelTime, Direction, RailRouteType, VersionID) are whole
-- numbers by definition — minutes, an enum, an ordinal, and a revision counter.
--
-- The USING clause is unnecessary (integer widens to double precision
-- implicitly) but is written out so the direction of the conversion is explicit.
-- The three failing systems have no rows to rewrite; TRTC's 22 rows convert 0
-- to 0.0.

ALTER TABLE raw_tdx.metro_route
    ALTER COLUMN routelength TYPE double precision USING routelength::double precision;
