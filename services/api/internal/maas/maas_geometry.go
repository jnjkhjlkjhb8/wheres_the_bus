package maas

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/go-resty/resty/v2"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"go.uber.org/zap"
	"golang.org/x/sync/errgroup"
)

// maas_geometry.go — walk-routing (OSRM) and transit-path/rail-shape
// geometry enrichment for MaaS plan responses. Split out of maas.go to
// keep that file within its size budget; no behavior change.

func enrichWalkSections(ctx context.Context, osrmClient *resty.Client, refs []maasSectionRef) {
	if osrmClient == nil {
		return
	}
	group, groupCtx := errgroup.WithContext(ctx)
	group.SetLimit(_maasOSRMConcurrency)
	for _, ref := range refs {
		if !isWalkSection(ref.source) {
			continue
		}

		group.Go(func() error {
			if err := groupCtx.Err(); err != nil {
				return err
			}
			secs, path, steps, ok := walkRoute(groupCtx, osrmClient, ref.target.Departure.Location, ref.target.Arrival.Location)
			if ok {
				ref.target.TravelSummary.Duration = secs
				ref.target.WalkPath = path
				ref.target.WalkSteps = steps
			}
			return nil
		})
	}
	_ = group.Wait()
}

func isWalkSection(sec tdxSection) bool {
	return strings.EqualFold(sec.Type, "pedestrian") ||
		sec.Transport.Mode == "" || strings.EqualFold(sec.Transport.Mode, "walk")
}

// osrmRouteResponse is the subset of the OSRM /route/v1/foot response the
// planner consumes: total duration, the geojson geometry, and the per-leg
// turn-by-turn steps.
type osrmRouteResponse struct {
	Code   string `json:"code"`
	Routes []struct {
		Duration float64 `json:"duration"`
		Geometry struct {
			Coordinates [][]float64 `json:"coordinates"`
		} `json:"geometry"`
		Legs []struct {
			Steps []struct {
				Distance float64 `json:"distance"`
				Duration float64 `json:"duration"`
				Name     string  `json:"name"`
				Maneuver struct {
					Type     string    `json:"type"`
					Modifier string    `json:"modifier"`
					Location []float64 `json:"location"`
				} `json:"maneuver"`
			} `json:"steps"`
		} `json:"legs"`
	} `json:"routes"`
}

func walkRoute(ctx context.Context, osrmClient *resty.Client, from, to *pb.Location) (int64, []*pb.Location, []*pb.WalkStep, bool) {
	if osrmClient == nil || from == nil || to == nil {
		return 0, nil, nil, false
	}
	if (from.Lat == 0 && from.Lng == 0) || (to.Lat == 0 && to.Lng == 0) {
		return 0, nil, nil, false
	}
	coords := fmt.Sprintf("%f,%f;%f,%f", from.Lng, from.Lat, to.Lng, to.Lat)
	var out osrmRouteResponse
	resp, err := osrmClient.R().
		SetContext(ctx).
		SetQueryParam("steps", "true").
		SetQueryParam("geometries", "geojson").
		SetQueryParam("overview", "full").
		SetResult(&out).
		Get(fmt.Sprintf("http://osrm:5000/route/v1/foot/%s", coords))
	if err != nil || !resp.IsSuccess() || out.Code != "Ok" || len(out.Routes) == 0 {
		return 0, nil, nil, false
	}
	route := out.Routes[0]
	path := make([]*pb.Location, 0, len(route.Geometry.Coordinates))
	for _, c := range route.Geometry.Coordinates {
		if len(c) < 2 {
			continue
		}
		// geojson coordinates are [lng, lat].
		path = append(path, &pb.Location{Lng: c[0], Lat: c[1]})
	}
	var steps []*pb.WalkStep
	for _, leg := range route.Legs {
		for _, st := range leg.Steps {
			step := &pb.WalkStep{
				Instruction:     walkInstruction(st.Maneuver.Type, st.Maneuver.Modifier, st.Name),
				ManeuverType:    st.Maneuver.Type,
				Modifier:        st.Maneuver.Modifier,
				DistanceMeters:  st.Distance,
				DurationSeconds: int64(st.Duration),
			}
			if len(st.Maneuver.Location) >= 2 {
				step.Location = &pb.Location{Lng: st.Maneuver.Location[0], Lat: st.Maneuver.Location[1]}
			}
			steps = append(steps, step)
		}
	}
	return int64(route.Duration), path, steps, true
}

func walkInstruction(maneuverType, modifier, name string) string {
	switch maneuverType {
	case "arrive":
		return "抵達目的地"
	case "depart":
		if name != "" {
			return fmt.Sprintf("沿%s出發", name)
		}
		return "開始步行"
	}
	turn := map[string]string{
		"left": "左轉", "right": "右轉",
		"slight left": "稍向左", "slight right": "稍向右",
		"sharp left": "向左急轉", "sharp right": "向右急轉",
		"uturn": "迴轉",
	}[modifier]
	switch {
	case turn != "" && name != "":
		return fmt.Sprintf("%s進入%s", turn, name)
	case turn != "":
		return turn
	case name != "":
		return fmt.Sprintf("沿%s直走", name)
	default:
		return "繼續直走"
	}
}

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
	switch {
	case isMetroMode(mode):
		return "metro"
	case isThsrMode(mode):
		return "thsr"
	case isRailMode(mode):
		return "tra"
	default:
		return ""
	}
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
	if len(path) > 0 {
		last := path[len(path)-1]
		if last.Lat == seg[0].Lat && last.Lng == seg[0].Lng {
			seg = seg[1:]
		}
	}
	return append(path, seg...)
}

// parseWKTLineString parses a PostGIS ST_AsText LINESTRING result into
// Locations. It never encounters MULTILINESTRING or any other geometry type
// since _transitPathClipSQL always clips a single dumped component.
func parseWKTLineString(wkt string) ([]*pb.Location, error) {
	wkt = strings.TrimSpace(wkt)
	open := strings.IndexByte(wkt, '(')
	closeIdx := strings.LastIndexByte(wkt, ')')
	if !strings.HasPrefix(strings.ToUpper(wkt), "LINESTRING") || open < 0 || closeIdx <= open {
		return nil, _oops.With("wkt", wkt).Errorf("not a LINESTRING")
	}
	body := wkt[open+1 : closeIdx]
	if strings.TrimSpace(body) == "" {
		return nil, _oops.With("wkt", wkt).Errorf("empty LINESTRING")
	}
	pairs := strings.Split(body, ",")
	points := make([]*pb.Location, 0, len(pairs))
	for _, pair := range pairs {
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
		points = append(points, &pb.Location{Lat: lat, Lng: lng})
	}
	return points, nil
}

func clipRailShape(ctx context.Context, db maasDB, mode string, a, b transitStopPoint) ([]*pb.Location, bool) {
	if db == nil {
		return nil, false
	}
	if (a.lat == 0 && a.lng == 0) || (b.lat == 0 && b.lng == 0) {
		return nil, false
	}
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
		return nil, false
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, false
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
		return nil, false
	}
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

func buildTransitPath(ctx context.Context, db maasDB, mode string, sec tdxSection) []*pb.Location {
	stops := sectionStopPoints(sec)
	if len(stops) < 2 {
		return nil
	}
	var path []*pb.Location
	for i := 0; i+1 < len(stops); i++ {
		a, b := stops[i], stops[i+1]
		seg, ok := clipRailShape(ctx, db, mode, a, b)
		if !ok {
			seg = []*pb.Location{{Lat: a.lat, Lng: a.lng}, {Lat: b.lat, Lng: b.lng}}
		}
		path = appendTransitSegment(path, seg)
	}
	return path
}

func enrichTransitPaths(ctx context.Context, db maasDB, refs []maasSectionRef) {
	if db == nil {
		return
	}
	group, groupCtx := errgroup.WithContext(ctx)
	group.SetLimit(_maasTransitPathConcurrency)
	for _, ref := range refs {
		mode := railShapeMode(ref.source.Transport.Mode)
		if mode == "" {
			continue
		}

		group.Go(func() error {
			if err := groupCtx.Err(); err != nil {
				return err
			}
			ref.target.TransitPath = buildTransitPath(groupCtx, db, mode, ref.source)
			return nil
		})
	}
	_ = group.Wait()
}
