package maas

import (
	"context"
	"strconv"
	"strings"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"go.uber.org/zap"
	"golang.org/x/sync/errgroup"
)

// maas_geometry.go — transit-path/rail-shape geometry enrichment for MaaS
// plan responses.

// Rail-mode classifiers. TDX MaaS mode strings vary by dataset; these cover the
// documented values (SUBWAY/METRO for metro, RAIL/TRA for conventional rail,
// THSR/HSR for high-speed rail).
func isMetroMode(mode string) bool {
	return strings.EqualFold(mode, "subway") || strings.EqualFold(mode, "metro") || strings.EqualFold(mode, "mrt")
}
func isThsrMode(mode string) bool {
	return strings.EqualFold(mode, "thsr") || strings.EqualFold(mode, "hsr")
}
func isRailMode(mode string) bool {
	return strings.EqualFold(mode, "rail") || strings.EqualFold(mode, "tra") || strings.EqualFold(mode, "train")
}

func isBusMode(mode string) bool {
	return strings.EqualFold(mode, "bus") || strings.EqualFold(mode, "HighwayBus")
}

// _maasTransitPathConcurrency bounds concurrent rail_shapes lookups the same
// way _maasOSRMConcurrency bounds OSRM lookups in enrichWalkSections.
const _maasTransitPathConcurrency = 4

const _railShapeSnapMeters = 500.0

// _railShapeSimplifyTolerance is the ST_SimplifyPreserveTopology tolerance (in
// degrees) applied to a clipped line before it is returned, trimming
// coordinate density without visibly changing the drawn path.
const _railShapeSimplifyTolerance = 0.0001

const _transitPathClipSQL = `
WITH candidates AS (
	SELECT ST_LineMerge(geom) AS merged
	FROM rail_shapes
	WHERE mode = $1
), scored AS (
	SELECT merged,
		GREATEST(
			ST_Distance(merged::geography, ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography),
			ST_Distance(merged::geography, ST_SetSRID(ST_MakePoint($4, $5), 4326)::geography)
		) AS score
	FROM candidates
), best AS (
	SELECT merged FROM scored ORDER BY score ASC LIMIT 1
), components AS (
	SELECT (ST_Dump(merged)).geom AS line FROM best
), matched AS (
	SELECT line,
		ST_Distance(line::geography, ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography) AS d1,
		ST_Distance(line::geography, ST_SetSRID(ST_MakePoint($4, $5), 4326)::geography) AS d2
	FROM components
), chosen AS (
	SELECT line FROM matched
	WHERE d1 <= $6 AND d2 <= $6
	ORDER BY GREATEST(d1, d2) ASC
	LIMIT 1
), located AS (
	SELECT line,
		ST_LineLocatePoint(line, ST_SetSRID(ST_MakePoint($2, $3), 4326)) AS f1,
		ST_LineLocatePoint(line, ST_SetSRID(ST_MakePoint($4, $5), 4326)) AS f2
	FROM chosen
)
SELECT ST_AsText(
	ST_SimplifyPreserveTopology(
		ST_LineSubstring(line, LEAST(f1, f2), GREATEST(f1, f2)),
		$7
	)
)
FROM located`

func railShapeMode(mode string) string {
	if isMetroMode(mode) {
		return "metro"
	}
	if isThsrMode(mode) {
		return "thsr"
	}
	if isRailMode(mode) {
		return "tra"
	}
	return ""
}

// transitStopPoint is one stop a transit section passes through, in travel
// order.
type transitStopPoint struct {
	lat, lng float64
}

// sectionStopPoints returns a section's ordered stop points: departure, every
// intermediate stop, then arrival. This is the sequence enrichTransitPaths
// clips one rail_shapes line between, pair by pair.
func sectionStopPoints(sec tdxSection) []transitStopPoint {
	points := make([]transitStopPoint, 0, 2+len(sec.IntermediateStops))
	points = append(points, transitStopPoint{sec.Departure.Place.Location.Lat, sec.Departure.Place.Location.Lng})
	for _, stop := range sec.IntermediateStops {
		points = append(points, transitStopPoint{stop.Departure.Place.Location.Lat, stop.Departure.Place.Location.Lng})
	}
	points = append(points, transitStopPoint{sec.Arrival.Place.Location.Lat, sec.Arrival.Place.Location.Lng})
	return points
}

func appendTransitSegment(path []*pb.Location, seg []*pb.Location) []*pb.Location {
	if len(seg) == 0 {
		return path
	}
	if joinsTransitSegment(path, seg[0]) {
		seg = seg[1:]
	}
	return append(path, seg...)
}

func joinsTransitSegment(path []*pb.Location, first *pb.Location) bool {
	if len(path) == 0 {
		return false
	}
	last := path[len(path)-1]
	return last.Lat == first.Lat && last.Lng == first.Lng
}

// parseWKTLineString parses a PostGIS ST_AsText LINESTRING result into
// Locations. It never encounters MULTILINESTRING or any other geometry type
// since _transitPathClipSQL always clips a single dumped component.
func parseWKTLineString(wkt string) ([]*pb.Location, error) {
	wkt = strings.TrimSpace(wkt)
	open := strings.IndexByte(wkt, '(')
	closeIdx := strings.LastIndexByte(wkt, ')')
	if !wktLineStringBounds(wkt, open, closeIdx) {
		return nil, _oops.With("wkt", wkt).Errorf("not a LINESTRING")
	}
	body := wkt[open+1 : closeIdx]
	if strings.TrimSpace(body) == "" {
		return nil, _oops.With("wkt", wkt).Errorf("empty LINESTRING")
	}
	return parseWKTPoints(body, wkt)
}

func wktLineStringBounds(wkt string, open, closeIdx int) bool {
	return strings.HasPrefix(strings.ToUpper(wkt), "LINESTRING") && open >= 0 && closeIdx > open
}

func parseWKTPoints(body, wkt string) ([]*pb.Location, error) {
	pairs := strings.Split(body, ",")
	points := make([]*pb.Location, 0, len(pairs))
	for _, pair := range pairs {
		point, err := parseWKTCoordinate(pair, wkt)
		if err != nil {
			return nil, err
		}
		points = append(points, point)
	}
	return points, nil
}

func parseWKTCoordinate(pair, wkt string) (*pb.Location, error) {
	fields := strings.Fields(strings.TrimSpace(pair))
	if len(fields) < 2 {
		return nil, _oops.With("pair", pair).With("wkt", wkt).Errorf("malformed coordinate")
	}
	lng, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return nil, _oops.With("fields", fields[0]).Wrapf(err, "parse lng")
	}
	lat, err := strconv.ParseFloat(fields[1], 64)
	if err != nil {
		return nil, _oops.With("fields", fields[1]).Wrapf(err, "parse lat")
	}
	return &pb.Location{Lat: lat, Lng: lng}, nil
}

func clipRailShape(ctx context.Context, db maasDB, mode string, a, b transitStopPoint) ([]*pb.Location, bool) {
	if db == nil {
		return nil, false
	}
	if !transitEndpointsUsable(a, b) {
		return nil, false
	}
	wkt, ok := railShapeWKT(ctx, db, mode, a, b)
	if !ok {
		return nil, false
	}
	return railShapePoints(wkt, mode)
}

func transitEndpointsUsable(a, b transitStopPoint) bool {
	return transitStopUsable(a) && transitStopUsable(b)
}

func railShapePoints(wkt, mode string) ([]*pb.Location, bool) {
	points, err := parseWKTLineString(wkt)
	if err != nil || len(points) < 2 {
		zap.S().Warnw("parse error",
			"component", "maas",
			"action", "transit_path",
			"event", "parse_error",
			"mode", mode,
			"err", err,
		)
		return nil, false
	}
	return points, true
}

func railShapeWKT(ctx context.Context, db maasDB, mode string, a, b transitStopPoint) (string, bool) {
	rows, err := db.Query(ctx, _transitPathClipSQL,
		mode, a.lng, a.lat, b.lng, b.lat, _railShapeSnapMeters, _railShapeSimplifyTolerance)
	if err != nil {
		zap.S().Warnw("query error",
			"component", "maas",
			"action", "transit_path",
			"event", "query_error",
			"mode", mode,
			"err", err,
		)
		return "", false
	}
	defer rows.Close()
	if !rows.Next() {
		return "", false
	}
	var wkt string
	if err := rows.Scan(&wkt); err != nil {
		zap.S().Warnw("scan error",
			"component", "maas",
			"action", "transit_path",
			"event", "scan_error",
			"mode", mode,
			"err", err,
		)
		return "", false
	}
	return wkt, true
}

func transitStopUsable(point transitStopPoint) bool {
	return point.lat != 0 || point.lng != 0
}

func buildTransitPath(ctx context.Context, db maasDB, shapes *railShapeCache, mode string, sec tdxSection) []*pb.Location {
	stops := sectionStopPoints(sec)
	var path []*pb.Location
	for i := 0; i+1 < len(stops); i++ {
		a, b := stops[i], stops[i+1]
		seg, ok := shapes.clip(ctx, db, mode, a, b)
		if !ok {
			seg = []*pb.Location{{Lat: a.lat, Lng: a.lng}, {Lat: b.lat, Lng: b.lng}}
		}
		path = appendTransitSegment(path, seg)
	}
	return path
}

func enrichTransitPath(ctx context.Context, db maasDB, shapes *railShapeCache, mode string, ref maasSectionRef) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	ref.target.TransitPath = buildTransitPath(ctx, db, shapes, mode, ref.source)
	return nil
}

// needsRailClip is false for non-rail sections and for those MOTIS already
// shaped.
func needsRailClip(mode string, ref maasSectionRef) bool {
	return mode != "" && len(ref.target.TransitPath) == 0
}

func enrichTransitPaths(ctx context.Context, db maasDB, shapes *railShapeCache, refs []maasSectionRef) {
	if db == nil {
		return
	}
	group, groupCtx := errgroup.WithContext(ctx)
	group.SetLimit(_maasTransitPathConcurrency)
	for _, ref := range refs {
		mode := railShapeMode(ref.source.Transport.Mode)
		if !needsRailClip(mode, ref) {
			continue
		}

		group.Go(func() error { return enrichTransitPath(groupCtx, db, shapes, mode, ref) })
	}
	_ = group.Wait()
}
