package maas

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-resty/resty/v2"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

const (
	// _maasBackendEnv selects the planner. Anything other than "tdx" means
	// MOTIS: the switch exists to fall back, so an unset or misspelled value
	// must not silently resurrect the backend being replaced.
	_maasBackendEnv      = "MAAS_BACKEND"
	_maasBackendTDX      = "tdx"
	_motisBaseURLEnv     = "MOTIS_BASE_URL"
	_motisDefaultBaseURL = "http://motis:8080"
	_motisPlanPath       = "/api/v6/plan"
	// _motisTimeout bounds one plan call. The shared work timeout is 20s and
	// covers fares and geometry on top of this, so the upstream call cannot be
	// allowed to consume all of it.
	_motisTimeout          = 12 * time.Second
	_motisExtraItineraries = 5
	_motisMaxItineraries   = 10
)

// errMotisNoItinerary marks an empty MOTIS result. It is an empty answer rather
// than a router fault, so it joins errMaasNoRoute and reaches the rider as
// NotFound instead of Unavailable.
var errMotisNoItinerary = errors.New("MOTIS has no itinerary for this origin/destination")

// MaasBackendFromEnv reports whether the TDX planner is selected. Every other
// value, including unset, selects MOTIS.
func MaasBackendFromEnv() (useTDX bool) {
	return strings.EqualFold(strings.TrimSpace(os.Getenv(_maasBackendEnv)), _maasBackendTDX)
}

// MotisBaseURLFromEnv reads where MOTIS is reached, defaulting to the service
// name on the routing network.
func MotisBaseURLFromEnv() string {
	if raw := strings.TrimSpace(os.Getenv(_motisBaseURLEnv)); raw != "" {
		return strings.TrimRight(raw, "/")
	}
	return _motisDefaultBaseURL
}

// motisClient is the MOTIS half of the planner. It holds no state beyond its
// HTTP client: MOTIS is a pure reader and every query is self-contained.
type motisClient struct {
	http *resty.Client
}

func NewMotisClient(baseURL string) *motisClient {
	return &motisClient{
		http: resty.New().
			SetBaseURL(baseURL).
			SetTimeout(_motisTimeout),
	}
}

// motisPlanResponse is the subset of MOTIS's plan result this router consumes.
type motisPlanResponse struct {
	Itineraries []motisItinerary `json:"itineraries"`
	// Opaque cursors for the 更早 / 更晚 departures action. Present only when
	// the query asked for a timetable view.
	PreviousPageCursor string `json:"previousPageCursor"`
	NextPageCursor     string `json:"nextPageCursor"`
}

type motisItinerary struct {
	Duration  int64      `json:"duration"`
	StartTime string     `json:"startTime"`
	EndTime   string     `json:"endTime"`
	Transfers int32      `json:"transfers"`
	Legs      []motisLeg `json:"legs"`
}

type motisLeg struct {
	Mode              string        `json:"mode"`
	From              motisPlace    `json:"from"`
	To                motisPlace    `json:"to"`
	Duration          int64         `json:"duration"`
	StartTime         string        `json:"startTime"`
	EndTime           string        `json:"endTime"`
	Distance          float64       `json:"distance"`
	Headsign          string        `json:"headsign"`
	RouteShortName    string        `json:"routeShortName"`
	RouteLongName     string        `json:"routeLongName"`
	RouteColor        string        `json:"routeColor"`
	DisplayName       string        `json:"displayName"`
	AgencyID          string        `json:"agencyId"`
	AgencyName        string        `json:"agencyName"`
	AgencyURL         string        `json:"agencyUrl"`
	IntermediateStops []motisPlace  `json:"intermediateStops"`
	LegGeometry       motisPolyline `json:"legGeometry"`
	Steps             []motisStep   `json:"steps"`
	Alternatives      [][]motisLeg  `json:"alternatives"`
}

type motisPlace struct {
	Name      string  `json:"name"`
	StopID    string  `json:"stopId"`
	Lat       float64 `json:"lat"`
	Lon       float64 `json:"lon"`
	Arrival   string  `json:"arrival"`
	Departure string  `json:"departure"`
}

type motisPolyline struct {
	Points    string `json:"points"`
	Precision int    `json:"precision"`
}

type motisStep struct {
	RelativeDirection string        `json:"relativeDirection"`
	Distance          float64       `json:"distance"`
	StreetName        string        `json:"streetName"`
	Polyline          motisPolyline `json:"polyline"`
}

type motisWalkGeometry struct {
	path  []*pb.Location
	steps []*pb.WalkStep
}

type motisPlanResult struct {
	api      *tdxAPIResponse
	geometry []*motisWalkGeometry
	previous string
	next     string
}

func (c *motisClient) Plan(
	ctx context.Context,
	req *pb.MaasPlanRequest,
) (*motisPlanResult, error) {
	var out motisPlanResponse
	resp, err := c.http.R().
		SetContext(ctx).
		SetQueryParamsFromValues(motisPlanQuery(req, time.Now())).
		SetResult(&out).
		Get(_motisPlanPath)
	if err != nil {
		return nil, _oops.Wrapf(err, "MOTIS plan")
	}
	if !resp.IsSuccess() {
		err := _oops.
			With("status_code", resp.StatusCode()).
			With("url", resp.Request.URL).
			With("string", strings.TrimSpace(resp.String())).
			Errorf("MOTIS plan HTTP")
		if resp.StatusCode() == http.StatusNotFound {
			return nil, _oops.Join(errMaasNoRoute, errMotisNoItinerary, err)
		}
		return nil, err
	}
	if len(out.Itineraries) == 0 {
		return nil, _oops.Join(errMaasNoRoute, errMotisNoItinerary)
	}
	api, geometry := convertMotisItineraries(out.Itineraries)
	return &motisPlanResult{
		api:      api,
		geometry: geometry,
		previous: out.PreviousPageCursor,
		next:     out.NextPageCursor,
	}, nil
}

func convertMotisItineraries(itineraries []motisItinerary) (*tdxAPIResponse, []*motisWalkGeometry) {
	api := &tdxAPIResponse{}
	geometry := make([]*motisWalkGeometry, 0)
	for _, itinerary := range itineraries {
		route := tdxRoute{
			TravelTime: itinerary.Duration,
			StartTime:  motisLocalTime(itinerary.StartTime),
			EndTime:    motisLocalTime(itinerary.EndTime),
			Transfers:  itinerary.Transfers,
		}
		for _, leg := range itinerary.Legs {
			route.Sections = append(route.Sections, motisSection(leg))
			geometry = append(geometry, motisLegGeometry(leg))
		}
		api.Data.Routes = append(api.Data.Routes, route)
	}
	return api, geometry
}

func motisSection(leg motisLeg) tdxSection {
	section := tdxSection{
		Type: motisSectionType(leg.Mode),
		TravelSummary: tdxSummary{
			Duration: leg.Duration,
			Length:   leg.Distance,
		},
		Departure: tdxPlaceInfo{
			Time: motisLocalTime(leg.StartTime),
			Place: tdxPlace{
				Name:     leg.From.Name,
				Type:     motisPlaceType(leg.From),
				Location: tdxLocation{Lat: leg.From.Lat, Lng: leg.From.Lon},
			},
		},
		Arrival: tdxPlaceInfo{
			Time: motisLocalTime(leg.EndTime),
			Place: tdxPlace{
				Name:     leg.To.Name,
				Type:     motisPlaceType(leg.To),
				Location: tdxLocation{Lat: leg.To.Lat, Lng: leg.To.Lon},
			},
		},
	}
	if mode := motisTransitMode(leg.Mode); mode != "" {
		section.Transport = tdxTransport{
			Mode:       mode,
			Name:       motisRouteName(leg),
			ShortName:  leg.RouteShortName,
			LongName:   leg.RouteLongName,
			Number:     leg.RouteShortName,
			Headsign:   leg.Headsign,
			RouteColor: leg.RouteColor,
		}
	}
	for _, stop := range leg.IntermediateStops {
		section.IntermediateStops = append(section.IntermediateStops, tdxStop{
			Departure: tdxPlaceInfo{
				Time: motisLocalTime(stop.Departure),
				Place: tdxPlace{
					Name:     stop.Name,
					Location: tdxLocation{Lat: stop.Lat, Lng: stop.Lon},
				},
			},
		})
	}
	if leg.AgencyName != "" {
		section.Agency = tdxAgency{
			AgencyID: leg.AgencyID,
			Name:     leg.AgencyName,
			Website:  leg.AgencyURL,
		}
	}
	for _, alternative := range leg.Alternatives {
		transit, ok := motisAlternativeLeg(alternative)
		if !ok {
			continue
		}
		section.Alternatives = append(section.Alternatives, motisSection(transit))
	}
	return section
}

func motisAlternativeLeg(legs []motisLeg) (motisLeg, bool) {
	for _, leg := range legs {
		if motisTransitMode(leg.Mode) != "" {
			return leg, true
		}
	}
	return motisLeg{}, false
}

func motisRouteName(leg motisLeg) string {
	if leg.DisplayName != "" {
		return leg.DisplayName
	}
	if leg.RouteShortName != "" {
		return leg.RouteShortName
	}
	return leg.RouteLongName
}

// motisSectionType maps a leg onto the section type the app branches on.
// Anything the rider travels on their own feet or a rented bike is a pedestrian
// section, which is also what [isWalkSection] tests.
func motisSectionType(mode string) string {
	if motisTransitMode(mode) == "" {
		return "pedestrian"
	}
	return "transit"
}

// motisPlaceType distinguishes a timetable stop from a street coordinate. TDX
// used the same two values, and the app renders a stop name differently from an
// address.
func motisPlaceType(place motisPlace) string {
	if place.StopID != "" {
		return "station"
	}
	return "place"
}

func motisTransitMode(mode string) string {
	switch strings.ToUpper(mode) {
	case "BUS":
		return "Bus"
	case "COACH":
		return "HighwayBus"
	case "SUBWAY":
		return "Subway"
	case "TRAM":
		return "Tram"
	case "HIGHSPEED_RAIL":
		return "THSR"
	case "RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN":
		return "Rail"
	case "FERRY":
		return "Ferry"
	case "AERIAL_LIFT", "FUNICULAR":
		return "CableCar"
	default:
		// WALK, BIKE, RENTAL, CAR and anything MOTIS adds later.
		return ""
	}
}

// motisLegGeometry lifts the street geometry MOTIS already computed for a walk
// leg. Transit legs return nil: their shape comes from the rail line lookup in
// enrichTransitPaths, which is a different source and a different question.
func motisLegGeometry(leg motisLeg) *motisWalkGeometry {
	if motisTransitMode(leg.Mode) != "" {
		return nil
	}
	path := decodeMotisPolyline(leg.LegGeometry)
	if len(path) == 0 && len(leg.Steps) == 0 {
		return nil
	}
	geometry := &motisWalkGeometry{path: path}
	for _, step := range leg.Steps {
		walkStep := &pb.WalkStep{
			Instruction:    motisStepInstruction(step),
			ManeuverType:   "turn",
			Modifier:       motisStepModifier(step.RelativeDirection),
			DistanceMeters: step.Distance,
		}
		if points := decodeMotisPolyline(step.Polyline); len(points) > 0 {
			walkStep.Location = points[0]
		}
		geometry.steps = append(geometry.steps, walkStep)
	}
	return geometry
}

// motisStepModifier maps MOTIS's relativeDirection onto the OSRM modifier
// vocabulary [walkInstruction] and the app already speak, so the turn-by-turn
// list renders identically whichever backend produced it.
func motisStepModifier(direction string) string {
	switch strings.ToUpper(direction) {
	case "HARD_LEFT":
		return "sharp left"
	case "HARD_RIGHT":
		return "sharp right"
	case "LEFT", "CONTINUE_LEFT":
		return "left"
	case "RIGHT", "CONTINUE_RIGHT":
		return "right"
	case "SLIGHTLY_LEFT":
		return "slight left"
	case "SLIGHTLY_RIGHT":
		return "slight right"
	case "UTURN_LEFT", "UTURN_RIGHT":
		return "uturn"
	default:
		// CONTINUE, DEPART, ELEVATOR, STAIRS and anything added later.
		return ""
	}
}

// motisStepInstruction composes the same Traditional Chinese sentence the OSRM
// path produced, reusing [walkInstruction] so the two backends cannot drift
// into two phrasings of the same turn.
func motisStepInstruction(step motisStep) string {
	switch strings.ToUpper(step.RelativeDirection) {
	case "DEPART":
		return walkInstruction("depart", "", step.StreetName)
	case "ARRIVE":
		return walkInstruction("arrive", "", step.StreetName)
	default:
		return walkInstruction("turn", motisStepModifier(step.RelativeDirection), step.StreetName)
	}
}

func applyMotisWalkGeometry(refs []maasSectionRef, geometry []*motisWalkGeometry) bool {
	if len(geometry) != len(refs) {
		return false
	}
	for i, ref := range refs {
		leg := geometry[i]
		if leg == nil || ref.target == nil {
			continue
		}
		ref.target.WalkPath = leg.path
		ref.target.WalkSteps = leg.steps
	}
	return true
}

func decodeMotisPolyline(line motisPolyline) []*pb.Location {
	if line.Points == "" {
		return nil
	}
	precision := line.Precision
	if precision <= 0 {
		return nil
	}
	scale := math.Pow10(precision)
	var (
		out     []*pb.Location
		lat     int64
		lng     int64
		index   int
		encoded = line.Points
	)
	readValue := func() (int64, bool) {
		var (
			shift  uint
			result int64
		)
		for {
			if index >= len(encoded) {
				return 0, false
			}
			b := int64(encoded[index]) - 63
			index++
			result |= (b & 0x1f) << shift
			if b < 0x20 {
				break
			}
			shift += 5
			if shift > 60 {
				return 0, false
			}
		}
		if result&1 != 0 {
			return ^(result >> 1), true
		}
		return result >> 1, true
	}
	for index < len(encoded) {
		dLat, ok := readValue()
		if !ok {
			return out
		}
		dLng, ok := readValue()
		if !ok {
			return out
		}
		lat += dLat
		lng += dLng
		out = append(out, &pb.Location{
			Lat: float64(lat) / scale,
			Lng: float64(lng) / scale,
		})
	}
	return out
}

func motisPlanQuery(req *pb.MaasPlanRequest, now time.Time) url.Values {
	query := url.Values{}
	query.Set("fromPlace", fmt.Sprintf("%.6f,%.6f", req.FromLat, req.FromLon))
	query.Set("toPlace", fmt.Sprintf("%.6f,%.6f", req.ToLat, req.ToLon))
	query.Set("time", motisTimeParam(req.Date, req.Time, req.ArriveBy, now))
	if req.ArriveBy {
		query.Set("arriveBy", "true")
	}

	top := clampInt(req.Top, 1, 10, 5)
	// More than the rider asked for, so rankMotisRoutes has alternatives to
	// weigh the price/time preference against before the list is trimmed back.
	query.Set("numItineraries", fmt.Sprintf("%d", min(top+_motisExtraItineraries, _motisMaxItineraries)))

	if modes := motisTransitModes(req.TransitModes); len(modes) > 0 {
		query.Set("transitModes", strings.Join(modes, ","))
	}
	tMin := clampInt(req.TransferTimeMin, 0, 60, 15)
	tMax := clampInt(req.TransferTimeMax, 0, 60, 60)
	query.Set("minTransferTime", fmt.Sprintf("%d", min(tMin, tMax)))

	firstModes, firstRental := motisMileModes(clampInt(req.FirstMileMode, 0, 3, 0))
	query.Set("preTransitModes", strings.Join(firstModes, ","))
	query.Set("maxPreTransitTime", fmt.Sprintf("%d", clampInt(req.FirstMileTime, 1, 60, 10)*60))
	lastModes, lastRental := motisMileModes(clampInt(req.LastMileMode, 0, 3, 0))
	query.Set("postTransitModes", strings.Join(lastModes, ","))
	query.Set("maxPostTransitTime", fmt.Sprintf("%d", clampInt(req.LastMileTime, 1, 60, 10)*60))
	// Shared bike is RENTAL plus a form-factor filter: without the filter MOTIS
	// would also offer scooters and cargo bikes from any GBFS feed that carries
	// them, which is not what the rider asked for by picking 共享單車.
	if firstRental {
		query.Set("preTransitRentalFormFactors", "BICYCLE")
	}
	if lastRental {
		query.Set("postTransitRentalFormFactors", "BICYCLE")
	}
	addMotisPreferences(query, req)
	return query
}

func addMotisPreferences(query url.Values, req *pb.MaasPlanRequest) {
	if req.Wheelchair {
		query.Set("pedestrianProfile", "WHEELCHAIR")
	}
	// Sent in metres per second, held in centimetres on the wire: the app
	// offers a few discrete paces, and an integer cannot disagree with itself
	// about what "slow" was.
	if speed := clampInt(req.WalkSpeedCmPerSec, 30, 250, 0); speed > 0 {
		query.Set("pedestrianSpeed", strconv.FormatFloat(float64(speed)/100, 'f', 2, 64))
	}
	// Zero is a request here -- direct connections only -- which is why the
	// field carries presence and this reads it rather than testing for zero.
	if req.MaxTransfers != nil {
		query.Set("maxTransfers", strconv.Itoa(int(clampInt(req.GetMaxTransfers(), 0, 5, 0))))
	}
	if req.AvoidReservation {
		query.Set("noCompulsoryReservation", "true")
	}
	if req.CarryBike {
		query.Set("requireBikeTransport", "true")
	}
	if cursor := strings.TrimSpace(req.PageCursor); cursor != "" {
		query.Set("pageCursor", cursor)
		// Paging only means anything against a timetable view: the default
		// search answers one departure window, and a cursor into it has nothing
		// to advance through.
		query.Set("timetableView", "true")
	}
	if alternatives := clampInt(req.LegAlternatives, 1, 5, 0); alternatives > 0 {
		query.Set("numLegAlternatives", strconv.Itoa(int(alternatives)))
	}
}

func motisLocalTime(ts string) string {
	parsed, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return ts
	}
	return parsed.In(time.Local).Format(time.RFC3339)
}

func motisTimeParam(date, timeStr string, _ bool, now time.Time) string {
	if len(timeStr) == len("HH:mm") {
		timeStr += ":00"
	}
	parsed, err := time.ParseInLocation("2006-01-02T15:04:05", date+"T"+timeStr, time.Local)
	if err != nil {
		return now.Format(time.RFC3339)
	}
	return parsed.Format(time.RFC3339)
}

func motisTransitModes(modes []int32) []string {
	byID := map[int32][]string{
		3: {"HIGHSPEED_RAIL"},
		4: {"REGIONAL_RAIL"},
		5: {"BUS", "COACH"},
		6: {"SUBWAY"},
		7: {"TRAM"},
		8: {"FERRY"},
		9: {"AERIAL_LIFT"},
	}
	seen := make(map[string]struct{}, len(modes))
	out := make([]string, 0, len(modes))
	for _, id := range modes {
		for _, mode := range byID[id] {
			if _, dup := seen[mode]; dup {
				continue
			}
			seen[mode] = struct{}{}
			out = append(out, mode)
		}
	}
	return out
}

func motisMileModes(mode int32) (modes []string, rental bool) {
	switch mode {
	case 1:
		return []string{"BIKE"}, false
	case 2:
		return []string{"CAR"}, false
	case 3:
		return []string{"RENTAL", "WALK"}, true
	default:
		return []string{"WALK"}, false
	}
}

func rankMotisRoutes(response *pb.MaasPlanResponse, gc float64, top int32) {
	if response == nil || len(response.Routes) <= 1 {
		return
	}
	if gc < 0 || gc > 1 {
		gc = 0
	}
	minTime, maxTime := response.Routes[0].TravelTime, response.Routes[0].TravelTime
	minFare, maxFare := response.Routes[0].TotalFare, response.Routes[0].TotalFare
	for _, route := range response.Routes {
		minTime = min(minTime, route.TravelTime)
		maxTime = max(maxTime, route.TravelTime)
		minFare = min(minFare, route.TotalFare)
		maxFare = max(maxFare, route.TotalFare)
	}
	// A zero span means every itinerary agrees on that axis, so it carries no
	// information and must not be allowed to divide by zero into one.
	normalise := func(value, low, high int64) float64 {
		if high <= low {
			return 0
		}
		return float64(value-low) / float64(high-low)
	}
	cost := make(map[*pb.Route]float64, len(response.Routes))
	for _, route := range response.Routes {
		timeCost := normalise(route.TravelTime, minTime, maxTime)
		fareCost := normalise(int64(route.TotalFare), int64(minFare), int64(maxFare))
		cost[route] = gc*timeCost + (1-gc)*fareCost
	}
	// SliceStable so itineraries the weighting cannot separate keep the order
	// MOTIS returned them in, which is by departure time.
	sort.SliceStable(response.Routes, func(i, j int) bool {
		return cost[response.Routes[i]] < cost[response.Routes[j]]
	})
	if limit := int(clampInt(top, 1, 10, 5)); len(response.Routes) > limit {
		response.Routes = response.Routes[:limit]
	}
}

// BackendName labels the selected planner for the startup log, so the
// answer to "which planner is this container running" is one grep away rather
// than an inference from an env dump.
func BackendName(usingMotis bool) string {
	if usingMotis {
		return "motis"
	}
	return _maasBackendTDX
}
