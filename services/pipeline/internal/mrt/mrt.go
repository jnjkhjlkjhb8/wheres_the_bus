package mrt

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
)

// mrtStation decodes a TDX Rail/Metro/Station element used for the metro static
// station table.
type mrtStation struct {
	StationPosition struct {
		PositionLon float64 `json:"PositionLon"`
		PositionLat float64 `json:"PositionLat"`
	} `json:"StationPosition"`
	LocationCity       string `json:"LocationCity"`
	StationID          string `json:"StationID"`
	BikeAllowOnHoliday bool   `json:"BikeAllowOnHoliday"`
	StationName        struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"StationName"`
}

// mrtFirstlast decodes a TDX Rail/Metro/FirstLastTimetable element: first/last
// train times per station, line, and destination for a weekly service pattern.
type mrtFirstlast struct {
	LineID                 string `json:"LineID"`
	StationID              string `json:"StationID"`
	TripHeadSign           string `json:"TripHeadSign"`
	DestinationStaionID    string `json:"DestinationStaionID"`
	DestinationStationName struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"DestinationStationName"`
	FirstTrainTime string `json:"FirstTrainTime"`
	LastTrainTime  string `json:"LastTrainTime"`
	ServiceDay     struct {
		Monday           bool `json:"Monday"`
		Tuesday          bool `json:"Tuesday"`
		Wednesday        bool `json:"Wednesday"`
		Thursday         bool `json:"Thursday"`
		Friday           bool `json:"Friday"`
		Saturday         bool `json:"Saturday"`
		Sunday           bool `json:"Sunday"`
		NationalHolidays bool `json:"NationalHolidays"`
	} `json:"ServiceDay"`
}

func validateMRTStation(_ int, station mrtStation) error {
	if strings.TrimSpace(station.StationID) == "" {
		return errors.New("StationID is required")
	}
	if !pipeline.ValidPosition(station.StationPosition.PositionLon, station.StationPosition.PositionLat) {
		return _oops.With("position_lon", station.StationPosition.PositionLon).With("position_lat", station.StationPosition.PositionLat).Errorf("position is invalid: lon= lat=")
	}
	return nil
}

func mrtStationRows(stations []mrtStation, system string) ([][]any, error) {
	row := [][]any{}
	seen := make(map[string][]any, len(stations))
	for _, temp := range stations {
		g := fmt.Sprintf("POINT(%.6f %.6f)", temp.StationPosition.PositionLon, temp.StationPosition.PositionLat)
		candidate := []any{
			g,
			system,
			temp.StationName.ZhTw,
			temp.LocationCity,
			temp.StationID,
			temp.BikeAllowOnHoliday,
		}
		if err := pipeline.AppendUniqueLoadRow(&row, seen, system+"\x00"+temp.StationID, "station", candidate); err != nil {
			return nil, _oops.With("system", system).Wrapf(err, "mrt stations")
		}
	}
	return row, nil
}

func LoadStations(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt stations: system is required")
	}
	stations, err := pipeline.DecodeLoadArray[mrtStation](dec, "mrt stations "+system, validateMRTStation)
	if err != nil {
		return err
	}
	row, err := mrtStationRows(stations, system)
	if err != nil {
		return err
	}
	return writeMRTStations(ctx, sink, row)
}

func writeMRTStations(ctx context.Context, sink pipeline.CopyUpsertSink, row [][]any) error {
	if len(row) == 0 {
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "mrt_station",
		CreateSQL: `CREATE TEMP TABLE temp_mrt (
					geom text,
					system text,
					name text,
					city text,
					id text,
					bike bool
				) ON COMMIT DROP;`,
		TempTable: "temp_mrt",
		CopyCols:  []string{"geom", "system", "name", "city", "id", "bike"},
		InsertSQL: `INSERT INTO mrt_station (
					stationposition,
					system,
					name,
					city,
					station_id,
					bikeallowonholiday,
					updated_at
				)
				SELECT st_geomfromtext(geom, 4326), system, name, city,id, bike,NOW() FROM temp_mrt
				ON CONFLICT (station_id,system) DO UPDATE SET name = EXCLUDED.name,city = excluded.city,stationposition = EXCLUDED.stationposition,bikeallowonholiday = EXCLUDED.bikeallowonholiday,updated_at = NOW();`,
	}, row)
}

func LoadFirstlast(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt first-last: system is required")
	}
	timetables, err := pipeline.DecodeLoadArray[mrtFirstlast](dec, "mrt first-last "+system, validateMRTFirstlast)
	if err != nil {
		return err
	}
	row := [][]any{}
	for _, temp := range timetables {
		row = append(row, []any{
			temp.StationID,
			temp.LineID,
			temp.TripHeadSign,
			temp.DestinationStaionID,
			temp.DestinationStationName.ZhTw,
			temp.FirstTrainTime,
			temp.LastTrainTime,
			pipeline.Mask(temp.ServiceDay.Monday, temp.ServiceDay.Tuesday, temp.ServiceDay.Wednesday, temp.ServiceDay.Thursday, temp.ServiceDay.Friday, temp.ServiceDay.Saturday, temp.ServiceDay.Sunday, temp.ServiceDay.NationalHolidays),
			system,
		})
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key:     "mrt_firstlast",
		PreExec: []pipeline.CopyUpsertStmt{{SQL: `DELETE FROM mrt_schedule WHERE system = $1`, Args: []any{system}}},
		CreateSQL: `CREATE TEMP TABLE temp_mrt (
                               id text,
                               lid text,
							   sign text,
                               dsid text,
                               dsname text,
                               ft text,
                               lt text,
       						   mask int2,
       						   sys text
					) ON COMMIT DROP;`,
		TempTable: "temp_mrt",
		CopyCols:  []string{"id", "lid", "sign", "dsid", "dsname", "ft", "lt", "mask", "sys"},
		InsertSQL: `INSERT INTO mrt_schedule (
						station_id,
						lineid,
						destinationstaionid,
						destinationstationname,
						firsttraintime,
						lasttraintime,
						serviceday,
						system,
						created_at,
						updated_at,
						trip_head_sign
					)
					SELECT DISTINCT ON (id, lid, dsid, mask, sys)
						id,lid, dsid, dsname, ft, lt,mask,sys,NOW(),NOW(),sign FROM temp_mrt
					ORDER BY id, lid, dsid, mask, sys, ft, lt, dsname, sign`,
	}, row)
}

// ServiceWindow is one first/last-train window from mrt_schedule, in minutes
// since midnight; last exceeds 1440 when the last train runs past midnight.

// _mrtWindowGraceMin pads each service window: a train can legitimately appear on
// the live board a few minutes before the first departure and linger a few
// minutes after the station's last-train time.

// _mrtWindowCacheTTL bounds how long the in-memory schedule windows are reused
// before re-reading mrt_schedule. The table only changes at the 03:30 daily
// load, so an hourly reload tracks it without a loader-side invalidation hook.

// parseHHMM parses "HH:MM" into minutes since midnight; ok is false for any
// other shape (mrt_schedule stores times as text straight from TDX).
func parseHHMM(s string) (int, bool) {
	if !validMRTClockText(s) {
		return 0, false
	}
	// TDX publishes past-midnight departures as hour 24+.
	h := int(s[0]-'0')*10 + int(s[1]-'0')
	m := int(s[3]-'0')*10 + int(s[4]-'0')
	if !boundedMRTClock(h, m) {
		return 0, false
	}
	return h*60 + m, true
}

func mrtClockShape(s string) bool           { return len(s) == 5 && s[2] == ':' }
func validMRTClockText(s string) bool       { return mrtClockShape(s) && mrtClockDigits(s) }
func boundedMRTClock(hour, minute int) bool { return hour <= 29 && minute <= 59 }

func isASCIIDigit(b byte) bool {
	return b >= '0' && b <= '9'
}

// stale beats none; nil on first failure

// last train past midnight belongs to the same service day

// Check the same clock time on both the current and previous service
// day, so 00:30 matches a 06:00–24:40 window via +24h.

// A 304 has already refreshed the cached arrivals' TTL via pipeline.BoundFetch.

// TDX encodes TravelTime as either a number or a quoted string.
type mrtODFare struct {
	OriginStationID      string      `json:"OriginStationID"`
	DestinationStationID string      `json:"DestinationStationID"`
	TravelTime           json.Number `json:"TravelTime"`
	Fares                []struct {
		TicketType int `json:"TicketType"`
		FareClass  int `json:"FareClass"`
		Price      int `json:"Price"`
	} `json:"Fares"`
}

// TDX fare codes used by the metro ODFare feed.
const (
	_mrtTicketTypeSingle = 1 // 單程票
	_mrtFareClassFull    = 1 // 全票
	_mrtFareClassHalf    = 2 // 半票
)

// fares picks the single-journey full (全票) and half (半票) prices. A class the
// feed omits stays 0, which the upsert preserves rather than overwriting a known
// price with a zero.
func (f mrtODFare) fares() (full, half int) {
	prices := map[int]int{}
	for _, fare := range f.Fares {
		if fare.TicketType == _mrtTicketTypeSingle {
			prices[fare.FareClass] = fare.Price
		}
	}
	return prices[_mrtFareClassFull], prices[_mrtFareClassHalf]
}

// travelTimeMin parses an mrtODFare's optional whole-minute TravelTime. Missing
// values return zero; malformed, fractional, or negative values are errors.
func (f mrtODFare) travelTimeMin() (int, error) {
	value, err := nonNegativeJSONInteger(f.TravelTime, "TravelTime", true /* optional */, _maxPostgresInteger)
	if err != nil {
		return 0, err
	}
	return int(value), nil
}

func mrtJourneyRows(fares []mrtODFare, system string) ([][]any, error) {
	rows := make([][]any, 0, len(fares))
	seen := make(map[string][]any, len(fares))
	for _, f := range fares {
		full, half := f.fares()
		travelTime, err := f.travelTimeMin()
		if err != nil {
			return nil, _oops.With("system", system).Wrapf(err, "mrt journey matrix row build")
		}
		id := fmt.Sprintf("%s-%s-%s", system, f.OriginStationID, f.DestinationStationID)
		candidate := []any{id, f.OriginStationID, f.DestinationStationID, system, travelTime, full, half}
		key := system + "\x00" + f.OriginStationID + "\x00" + f.DestinationStationID
		if err := pipeline.AppendUniqueLoadRow(&rows, seen, key, "OD", candidate); err != nil {
			return nil, _oops.With("system", system).Wrapf(err, "mrt journey matrix")
		}
	}
	return rows, nil
}

func LoadJourneyMatrix(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt journey matrix: system is required")
	}
	fares, err := pipeline.DecodeLoadArray[mrtODFare](dec, "mrt journey matrix "+system, validateMRTJourneyFare)
	if err != nil {
		return err
	}
	rows, err := mrtJourneyRows(fares, system)
	if err != nil {
		return err
	}
	return writeMRTJourneyRows(ctx, sink, rows)
}

func writeMRTJourneyRows(ctx context.Context, sink pipeline.CopyUpsertSink, rows [][]any) error {
	if len(rows) == 0 {
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "mrt_journey_matrix",
		CreateSQL: `CREATE TEMP TABLE temp_mrt_journey_matrix (
			id text, from_station_id text, to_station_id text, system text,
			travel_time_min int, fare_nt int, half_fare_nt int
		) ON COMMIT DROP`,
		TempTable: "temp_mrt_journey_matrix",
		CopyCols:  []string{"id", "from_station_id", "to_station_id", "system", "travel_time_min", "fare_nt", "half_fare_nt"},
		InsertSQL: `INSERT INTO mrt_journey_matrix
			(id, from_station_id, to_station_id, system, travel_time_min, fare_nt, half_fare_nt, updated_at)
			SELECT id, from_station_id, to_station_id, system, travel_time_min, fare_nt, half_fare_nt, NOW()
			FROM temp_mrt_journey_matrix
			ON CONFLICT (from_station_id, to_station_id, system)
			DO UPDATE SET
				fare_nt = CASE WHEN EXCLUDED.fare_nt > 0
					THEN EXCLUDED.fare_nt ELSE mrt_journey_matrix.fare_nt END,
				half_fare_nt = CASE WHEN EXCLUDED.half_fare_nt > 0
					THEN EXCLUDED.half_fare_nt ELSE mrt_journey_matrix.half_fare_nt END,
				travel_time_min = CASE WHEN EXCLUDED.travel_time_min > 0
					THEN EXCLUDED.travel_time_min ELSE mrt_journey_matrix.travel_time_min END,
				updated_at = NOW()`,
	}, rows)
}

const _maxPostgresInteger int64 = 1<<31 - 1

func nonNegativeJSONInteger(number json.Number, field string, optional bool, maximum int64) (int64, error) {
	if number == "" {
		return missingMRTNumber(field, optional)
	}
	value, err := parseExactMRTNumber(number, field)
	if err != nil {
		return 0, err
	}
	return boundedMRTInteger(value, number, field, maximum)
}

func missingMRTNumber(field string, optional bool) (int64, error) {
	if optional {
		return 0, nil
	}
	return 0, _oops.With("field", field).Errorf("is required")
}

func parseExactMRTNumber(number json.Number, field string) (*big.Rat, error) {
	value, ok := new(big.Rat).SetString(number.String())
	if !ok || value.Sign() < 0 {
		return nil, _oops.With("field", field).With("number", number).Errorf("must be an exact non-negative number")
	}
	if !value.IsInt() {
		return nil, _oops.With("field", field).With("number", number).Errorf("must use whole units")
	}
	return value, nil
}

func boundedMRTInteger(value *big.Rat, number json.Number, field string, maximum int64) (int64, error) {
	integer := value.Num()
	if !integer.IsInt64() || integer.Int64() > maximum {
		return 0, _oops.With("field", field).With("maximum", maximum).With("number", number).Errorf("must be between 0")
	}
	return integer.Int64(), nil
}

type mrtTravelSegment struct {
	FromStationID string      `json:"FromStationID"`
	ToStationID   string      `json:"ToStationID"`
	RunTime       json.Number `json:"RunTime"`
	StopTime      json.Number `json:"StopTime"`
}

type mrtS2SRow struct {
	TravelTimes []mrtTravelSegment `json:"TravelTimes"`
}

// mrtLineTransfer decodes one TDX Rail/Metro/LineTransfer element: an interchange
// edge between two station IDs. TransferTime is whole minutes per the TDX schema.
type mrtLineTransfer struct {
	FromStationID string      `json:"FromStationID"`
	ToStationID   string      `json:"ToStationID"`
	TransferTime  json.Number `json:"TransferTime"`
}

// jsonNumInt parses a required whole-unit duration without silently converting
// malformed values to zero.
func jsonNumInt(n json.Number, field string) (int64, error) {
	value, err := nonNegativeJSONInteger(n, field, false /* optional */, _maxPostgresInteger)
	if err != nil {
		return 0, err
	}
	return value, nil
}

func LoadTrtcTravelTime(ctx context.Context, src pipeline.LoadSource, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt travel time: system is required")
	}
	lines, transfers, err := readMRTTravelData(ctx, src, system)
	if err != nil {
		return err
	}
	return writeMRTTravelGraph(ctx, sink, lines, transfers, system)
}

func writeMRTTravelGraph(ctx context.Context, sink pipeline.CopyUpsertSink, lines []mrtS2SRow, transfers []mrtLineTransfer, system string) error {
	stations, dist, segCount, transferCount, err := mrtTravelGraph(lines, transfers)
	if err != nil {
		return _oops.With("system", system).Wrapf(err, "mrt travel graph")
	}
	if !hasMRTTravelSegments(stations, segCount) {
		zap.S().Infow("no graph",
			"component", "mrt",
			"action", "trtc_traveltime",
			"system", system,
			"event", "no_graph",
			"segments", segCount,
			"transfers", transferCount,
		)
		return nil
	}
	return writeMRTTravelTimes(ctx, sink, system, stations, dist)
}

func writeMRTTravelTimes(ctx context.Context, sink pipeline.CopyUpsertSink, system string, stations []string, dist [][]int64) error {
	rows, err := mrtTravelTimeRows(system, stations, dist)
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "mrt_traveltime",
		CreateSQL: `CREATE TEMP TABLE temp_mrt_travel_time (
			travel_time_min int, from_station_id text, to_station_id text, system text
		) ON COMMIT DROP`,
		TempTable: "temp_mrt_travel_time",
		CopyCols:  []string{"travel_time_min", "from_station_id", "to_station_id", "system"},
		InsertSQL: `UPDATE mrt_journey_matrix AS matrix
			SET travel_time_min = fresh.travel_time_min, updated_at = NOW()
			FROM temp_mrt_travel_time AS fresh
			WHERE matrix.from_station_id = fresh.from_station_id
			  AND matrix.to_station_id = fresh.to_station_id
			  AND matrix.system = fresh.system`,
	}, rows)
}

type AdjacencyRow struct {
	LineID      string `json:"LineID"`
	TravelTimes []struct {
		FromStationID string `json:"FromStationID"`
		ToStationID   string `json:"ToStationID"`
	} `json:"TravelTimes"`
}

func validateMRTAdjacency(_ int, line AdjacencyRow) error {
	if strings.TrimSpace(line.LineID) == "" {
		return errors.New("LineID is required")
	}
	return validateMRTAdjacencySegments(line)
}

func validateMRTAdjacencySegments(line AdjacencyRow) error {
	for index, segment := range line.TravelTimes {
		if err := validateMRTSegmentIdentity(index, segment.FromStationID, segment.ToStationID); err != nil {
			return err
		}
	}
	return nil
}

func LoadAdjacency(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, system string) error {
	if strings.TrimSpace(system) == "" {
		return errors.New("mrt adjacency: system is required")
	}
	lines, err := pipeline.DecodeLoadArray[AdjacencyRow](dec, "mrt adjacency "+system, validateMRTAdjacency)
	if err != nil {
		return err
	}
	rows := AdjacencyRows(lines, system)
	if len(rows) == 0 {
		zap.S().Infow("no edges",
			"component", "mrt",
			"action", "mrt_adjacency",
			"system", system,
			"event", "no_edges",
		)
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "mrt_adjacency",
		CreateSQL: `CREATE TEMP TABLE temp_mrt_adjacency (
			system text, line_id text, from_station_id text, to_station_id text
		) ON COMMIT DROP`,
		TempTable: "temp_mrt_adjacency",
		CopyCols:  []string{"system", "line_id", "from_station_id", "to_station_id"},
		InsertSQL: `INSERT INTO mrt_adjacency (system, line_id, from_station_id, to_station_id, updated_at)
			SELECT system, line_id, from_station_id, to_station_id, NOW() FROM temp_mrt_adjacency
			ON CONFLICT (system, from_station_id, to_station_id)
			DO UPDATE SET line_id = EXCLUDED.line_id, updated_at = NOW()`,
	}, rows)
}

type mrtAdjacencyBuilder struct {
	system string
	seen   map[string]bool
	rows   [][]any
}

func AdjacencyRows(lines []AdjacencyRow, system string) [][]any {
	b := mrtAdjacencyBuilder{system: system, seen: map[string]bool{}}
	for _, line := range lines {
		b.addLine(line)
	}
	return b.rows
}

func (b *mrtAdjacencyBuilder) addLine(line AdjacencyRow) {
	for _, segment := range line.TravelTimes {
		b.addPair(line.LineID, segment.FromStationID, segment.ToStationID)
	}
}

func (b *mrtAdjacencyBuilder) addPair(lineID, from, to string) {
	if from == "" || to == "" {
		return
	}
	b.add(lineID, from, to)
	b.add(lineID, to, from)
}

func (b *mrtAdjacencyBuilder) add(lineID, from, to string) {
	key := from + "\x00" + to
	if b.seen[key] {
		return
	}
	b.seen[key] = true
	b.rows = append(b.rows, []any{b.system, lineID, from, to})
}

const _mrtGraphInf int64 = 1 << 62

type mrtTravelEdge struct {
	a, b int
	w    int64
}
type mrtTravelGraphBuilder struct {
	stations            []string
	index               map[string]int
	edges               []mrtTravelEdge
	segments, transfers int
}

func mrtTravelGraph(lines []mrtS2SRow, transfers []mrtLineTransfer) ([]string, [][]int64, int, int, error) {
	b := mrtTravelGraphBuilder{stations: []string{}, index: make(map[string]int)}
	if err := b.addLines(lines); err != nil {
		return nil, nil, 0, 0, err
	}
	if err := b.addTransfers(transfers); err != nil {
		return nil, nil, 0, 0, err
	}
	dist := initialMRTDistances(len(b.stations), b.edges)
	relaxMRTDistances(dist)
	return b.stations, dist, b.segments, b.transfers, nil
}

func (b *mrtTravelGraphBuilder) addLines(lines []mrtS2SRow) error {
	for _, line := range lines {
		if err := b.addLine(line); err != nil {
			return err
		}
	}
	return nil
}

func (b *mrtTravelGraphBuilder) addTransfers(transfers []mrtLineTransfer) error {
	for _, transfer := range transfers {
		if err := b.addTransfer(transfer); err != nil {
			return err
		}
	}
	return nil
}

func (b *mrtTravelGraphBuilder) stationID(station string) int {
	if i, ok := b.index[station]; ok {
		return i
	}
	i := len(b.stations)
	b.index[station] = i
	b.stations = append(b.stations, station)
	return i
}
func (b *mrtTravelGraphBuilder) addLine(line mrtS2SRow) error {
	for _, segment := range line.TravelTimes {
		if err := b.addSegment(segment); err != nil {
			return err
		}
	}
	return nil
}

func hasMRTStationPair(from, to string) bool { return from != "" && to != "" }

func mrtSegmentDuration(segment mrtTravelSegment) (int64, error) {
	runTime, err := jsonNumInt(segment.RunTime, "RunTime")
	if err != nil {
		return 0, err
	}
	stopTime, err := jsonNumInt(segment.StopTime, "StopTime")
	if err != nil {
		return 0, err
	}
	return runTime + stopTime, nil
}

func (b *mrtTravelGraphBuilder) addSegment(segment mrtTravelSegment) error {
	if !hasMRTStationPair(segment.FromStationID, segment.ToStationID) {
		return nil
	}
	duration, err := mrtSegmentDuration(segment)
	if err != nil {
		return err
	}
	b.edges = append(b.edges, mrtTravelEdge{b.stationID(segment.FromStationID), b.stationID(segment.ToStationID), duration})
	b.segments++
	return nil
}
func (b *mrtTravelGraphBuilder) addTransfer(transfer mrtLineTransfer) error {
	if !hasMRTStationPair(transfer.FromStationID, transfer.ToStationID) {
		return nil
	}
	duration, err := jsonNumInt(transfer.TransferTime, "TransferTime")
	if err != nil {
		return err
	}
	b.edges = append(b.edges, mrtTravelEdge{b.stationID(transfer.FromStationID), b.stationID(transfer.ToStationID), duration * 60})
	b.transfers++
	return nil
}
func initialMRTDistances(n int, edges []mrtTravelEdge) [][]int64 {
	dist := make([][]int64, n)
	for i := range dist {
		dist[i] = initialMRTDistanceRow(n, i)
	}
	applyMRTTravelEdges(dist, edges)
	return dist
}

func initialMRTDistanceRow(n, origin int) []int64 {
	row := make([]int64, n)
	for destination := range row {
		if origin != destination {
			row[destination] = _mrtGraphInf
		}
	}
	return row
}

func applyMRTTravelEdges(dist [][]int64, edges []mrtTravelEdge) {
	for _, edge := range edges {
		if edge.w < dist[edge.a][edge.b] {
			dist[edge.a][edge.b] = edge.w
			dist[edge.b][edge.a] = edge.w
		}
	}
}
func relaxMRTDistances(dist [][]int64) {
	n := len(dist)
	for k := range n {
		for i := range n {
			if dist[i][k] >= _mrtGraphInf {
				continue
			}
			relaxMRTDistanceRow(dist, i, k)
		}
	}
}
func relaxMRTDistanceRow(dist [][]int64, i, k int) {
	for j := range dist {
		relaxMRTPath(dist, i, j, k)
	}
}

func boundedMRTPath(a, b int64) bool { return b < _mrtGraphInf && a <= _mrtGraphInf-b }

func relaxMRTPath(dist [][]int64, i, j, k int) {
	if !boundedMRTPath(dist[i][k], dist[k][j]) {
		return
	}
	if distance := dist[i][k] + dist[k][j]; distance < dist[i][j] {
		dist[i][j] = distance
	}
}

func validateMRTTimetableIdentity(timetable mrtFirstlast) error {
	if strings.TrimSpace(timetable.StationID) == "" {
		return errors.New("StationID is required")
	}
	if strings.TrimSpace(timetable.LineID) == "" {
		return errors.New("LineID is required")
	}
	if strings.TrimSpace(timetable.DestinationStaionID) == "" {
		return errors.New("DestinationStaionID is required")
	}
	return nil
}

func validateMRTFirstlast(_ int, timetable mrtFirstlast) error {
	if err := validateMRTTimetableIdentity(timetable); err != nil {
		return err
	}
	if err := validateMRTTimetableClocks(timetable); err != nil {
		return err
	}
	return validateMRTServiceDays(timetable)
}

func validateMRTTimetableClocks(timetable mrtFirstlast) error {
	if !validOptionalMRTClock(timetable.FirstTrainTime) {
		return _oops.With("first_train_time", timetable.FirstTrainTime).Errorf("FirstTrainTime is invalid")
	}
	if !validOptionalMRTClock(timetable.LastTrainTime) {
		return _oops.With("last_train_time", timetable.LastTrainTime).Errorf("LastTrainTime is invalid")
	}
	return nil
}

func validateMRTServiceDays(timetable mrtFirstlast) error {
	if pipeline.Mask(timetable.ServiceDay.Monday, timetable.ServiceDay.Tuesday, timetable.ServiceDay.Wednesday,
		timetable.ServiceDay.Thursday, timetable.ServiceDay.Friday, timetable.ServiceDay.Saturday,
		timetable.ServiceDay.Sunday, timetable.ServiceDay.NationalHolidays) == 0 {
		return errors.New("ServiceDay must enable at least one day")
	}
	return nil
}

func validateMRTJourneyFare(_ int, fare mrtODFare) error {
	if strings.TrimSpace(fare.OriginStationID) == "" {
		return errors.New("OriginStationID is required")
	}
	if strings.TrimSpace(fare.DestinationStationID) == "" {
		return errors.New("DestinationStationID is required")
	}
	if _, err := fare.travelTimeMin(); err != nil {
		return err
	}
	return validateMRTFarePrices(fare)

}

func validOptionalMRTClock(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" {
		return true
	}
	_, ok := parseHHMM(value)
	return ok
}
func mrtClockDigits(s string) bool {
	return isASCIIDigit(s[0]) && isASCIIDigit(s[1]) && isASCIIDigit(s[3]) && isASCIIDigit(s[4])
}

func validateMRTFarePrices(fare mrtODFare) error {
	singleSeen, err := collectMRTFarePrices(fare)
	if err != nil {
		return err
	}
	if !singleSeen {
		return errors.New("fares must include TicketType 1")
	}
	return nil
}

func collectMRTFarePrices(fare mrtODFare) (bool, error) {
	singleSeen := false
	classPrices := map[int]int{}
	for i := range fare.Fares {
		single, err := validateMRTFarePrice(fare, i, classPrices)
		if err != nil {
			return false, err
		}
		singleSeen = singleSeen || single
	}
	return singleSeen, nil
}

func validateMRTFarePrice(fare mrtODFare, index int, prices map[int]int) (bool, error) {
	if err := validateMRTFareItem(fare, index); err != nil {
		return false, err
	}
	if fare.Fares[index].TicketType != _mrtTicketTypeSingle {
		return false, nil
	}
	err := recordMRTSingleFarePrice(fare, index, prices)
	return true, err
}

func validateMRTFareItem(fare mrtODFare, i int) error {
	item := fare.Fares[i]
	if item.TicketType <= 0 {
		return _oops.With("index", i).With("ticket_type", item.TicketType).Errorf("fares element TicketType must be positive")
	}
	if item.FareClass < 0 {
		return _oops.With("index", i).With("fare_class", item.FareClass).Errorf("fares element FareClass must be non-negative")
	}
	if item.Price < 0 {
		return _oops.With("index", i).With("price", item.Price).Errorf("fares element Price must be non-negative")
	}
	return nil
}
func knownMRTFareClass(class int) bool {
	return class == _mrtFareClassFull || class == _mrtFareClassHalf
}

func recordMRTSingleFarePrice(fare mrtODFare, i int, classPrices map[int]int) error {
	item := fare.Fares[i]
	if knownMRTFareClass(item.FareClass) {
		if prior, seen := classPrices[item.FareClass]; seen && prior != item.Price {
			return _oops.With("index", i).With("fare_class", item.FareClass).Errorf("fares element divergent duplicate TicketType 1 FareClass")
		}
		classPrices[item.FareClass] = item.Price
	}
	return nil
}

func validateMRTTravelLine(_ int, line mrtS2SRow) error {
	for i, segment := range line.TravelTimes {
		if err := validateMRTTravelSegment(i, segment); err != nil {
			return err
		}
	}
	return nil
}

func validateMRTSegmentIdentity(index int, from, to string) error {
	if strings.TrimSpace(from) == "" {
		return _oops.With("index", index).Errorf("TravelTimes element FromStationID is required")
	}
	if strings.TrimSpace(to) == "" {
		return _oops.With("index", index).Errorf("TravelTimes element ToStationID is required")
	}
	return nil
}

func positiveMRTDuration(number json.Number, field string) error {
	value, err := nonNegativeJSONInteger(number, field, false, _maxPostgresInteger)
	if err != nil {
		return err
	}
	if value == 0 {
		return errors.New(field + " must be positive")
	}
	return nil
}

func validateMRTTravelSegment(index int, segment mrtTravelSegment) error {
	if err := validateMRTSegmentIdentity(index, segment.FromStationID, segment.ToStationID); err != nil {
		return err
	}
	return validateMRTSegmentTimes(index, segment)
}

func validateMRTSegmentTimes(index int, segment mrtTravelSegment) error {
	if err := positiveMRTDuration(segment.RunTime, "RunTime"); err != nil {
		return _oops.With("index", index).Wrapf(err, "TravelTimes element")
	}
	if _, err := nonNegativeJSONInteger(segment.StopTime, "StopTime", false, _maxPostgresInteger); err != nil {
		return _oops.With("index", index).Wrapf(err, "TravelTimes element")
	}
	return nil
}

func validateMRTTransferIdentity(transfer mrtLineTransfer) error {
	if strings.TrimSpace(transfer.FromStationID) == "" {
		return errors.New("FromStationID is required")
	}
	if strings.TrimSpace(transfer.ToStationID) == "" {
		return errors.New("ToStationID is required")
	}
	return nil
}

func validateMRTTransfer(_ int, transfer mrtLineTransfer) error {
	if err := validateMRTTransferIdentity(transfer); err != nil {
		return err
	}
	return positiveMRTDuration(transfer.TransferTime, "TransferTime")
}

func readMRTTravelLines(ctx context.Context, src pipeline.LoadSource, system string) ([]mrtS2SRow, error) {
	body, _, err := src.DatasetJSON(ctx, "metro_s2straveltime", "system", system)
	if err != nil {
		return nil, _oops.With("system", system).Wrapf(err, "mrt s2s read")
	}
	return pipeline.DecodeLoadArray[mrtS2SRow](json.NewDecoder(bytes.NewReader(body)), "mrt s2s "+system, validateMRTTravelLine)
}

func readMRTTransfers(ctx context.Context, src pipeline.LoadSource, system string) ([]mrtLineTransfer, error) {
	body, _, err := src.DatasetJSON(ctx, "metro_linetransfer", "system", system)
	if err != nil {
		return nil, _oops.With("system", system).Wrapf(err, "mrt linetransfer read")
	}
	return pipeline.DecodeLoadArray[mrtLineTransfer](json.NewDecoder(bytes.NewReader(body)), "mrt line transfer "+system, validateMRTTransfer)
}

func readMRTTravelData(ctx context.Context, src pipeline.LoadSource, system string) ([]mrtS2SRow, []mrtLineTransfer, error) {
	lines, err := readMRTTravelLines(ctx, src, system)
	if err != nil {
		return nil, nil, err
	}
	transfers, err := readMRTTransfers(ctx, src, system)
	if err != nil {
		return nil, nil, err
	}
	return lines, transfers, nil
}

func mrtTravelTimeRows(system string, stations []string, dist [][]int64) ([][]any, error) {
	// Only existing OD rows are updated; station ordering keeps COPY deterministic.
	rows := make([][]any, 0, len(stations)*len(stations))
	for i, from := range stations {
		part, err := mrtOriginTravelRows(system, from, stations, dist[i], i)
		if err != nil {
			return nil, err
		}
		rows = append(rows, part...)
	}
	return rows, nil
}

func mrtOriginTravelRows(system, from string, stations []string, distances []int64, origin int) ([][]any, error) {
	rows := [][]any{}
	for j, to := range stations {
		row, err := mrtPairTravelRow(system, from, to, distances[j], origin == j)
		if err != nil {
			return nil, err
		}
		if row != nil {
			rows = append(rows, row)
		}
	}
	return rows, nil
}

func usableMRTDistance(distance int64, self bool) bool {
	return !self && distance > 0 && distance < _mrtGraphInf
}

func mrtPairTravelRow(system, from, to string, distance int64, self bool) ([]any, error) {
	if !usableMRTDistance(distance, self) {
		return nil, nil
	}
	mins := max((distance+30)/60, 1)
	if mins > _maxPostgresInteger {
		return nil, _oops.With("system", system).With("from", from).With("to", to).Errorf("mrt travel time to exceeds PostgreSQL integer maximum")
	}
	return []any{mins, from, to, system}, nil
}

func hasMRTTravelSegments(stations []string, count int) bool { return len(stations) != 0 && count != 0 }
