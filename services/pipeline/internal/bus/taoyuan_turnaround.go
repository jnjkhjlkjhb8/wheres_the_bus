package bus

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"slices"
	"strings"

	"github.com/go-resty/resty/v2"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// Taoyuan's 2026 static overhaul republished its out-and-back routes as one
// TDX direction whose stop list runs out to a turnaround and back. Only the
// city's own TaoyuanRoute feed names that turnaround (backStopId), and only as
// XML, so it is landed beside the regular Bus datasets rather than through them.
const (
	_taoyuanCity          = "Taoyuan"
	_taoyuanRouteTable    = "bus_taoyuanroute"
	TaoyuanRouteBaseURL   = "https://tdx.transportdata.tw/api/taoyuanbus"
	_taoyuanRouteEndpoint = "/v2/Bus/TaoyuanRoute"
)

type taoyuanRouteFeed struct {
	UpdateTime string              `xml:"EssentialInfo>UpdateTime"`
	Routes     []taoyuanRouteEntry `xml:"BusInfo>Route"`
}

type taoyuanRouteEntry struct {
	ID         string `xml:"ID,attr"`
	IsCircular string `xml:"IsCircular,attr"`
	BackStopID string `xml:"backStopId,attr"`
}

// taoyuanTurnaroundRow is one raw_tdx.bus_taoyuanroute row. Its keys are the
// table's columns: the raw insert lowercases them onto the record.
type taoyuanTurnaroundRow struct {
	SubRouteUID string `json:"SubRouteUID"`
	IsCircular  bool   `json:"IsCircular"`
	BackStopUID string `json:"BackStopUID"`
}

// LandTaoyuanTurnarounds lands the TaoyuanRoute turnaround stops. client must be
// a TDX-authenticated client rooted at TaoyuanRouteBaseURL.
func LandTaoyuanTurnarounds(ctx context.Context, client *resty.Client) error {
	resp, err := client.R().SetContext(ctx).SetQueryParam("$format", "XML").Get(_taoyuanRouteEndpoint)
	if err != nil {
		return _oops.Wrapf(err, "fetch TaoyuanRoute")
	}
	if resp.IsError() {
		return _oops.With("status", resp.StatusCode()).Errorf("fetch TaoyuanRoute: unexpected status")
	}
	feed, rows, err := taoyuanTurnaroundRows(resp.Body())
	if err != nil {
		return err
	}
	return dumpTaoyuanTurnarounds(ctx, feed.UpdateTime, rows)
}

func taoyuanTurnaroundRows(body []byte) (taoyuanRouteFeed, []taoyuanTurnaroundRow, error) {
	var feed taoyuanRouteFeed
	if err := xml.Unmarshal(body, &feed); err != nil {
		return feed, nil, _oops.Wrapf(err, "decode TaoyuanRoute")
	}
	if len(feed.Routes) == 0 {
		return feed, nil, _oops.Wrapf(errBusSnapshotInvalid, "TaoyuanRoute has no routes")
	}
	return feed, taoyuanTurnaroundsOf(feed.Routes), nil
}

func taoyuanTurnaroundsOf(routes []taoyuanRouteEntry) []taoyuanTurnaroundRow {
	rows := make([]taoyuanTurnaroundRow, 0, len(routes))
	for _, r := range routes {
		if row, ok := taoyuanTurnaround(r); ok {
			rows = append(rows, row)
		}
	}
	return rows
}

// taoyuanTurnaround maps a feed route onto TDX's UIDs, which are the city
// prefix plus the feed's own route and stop IDs.
func taoyuanTurnaround(r taoyuanRouteEntry) (taoyuanTurnaroundRow, bool) {
	prefix := busmodel.CityPrefix[_taoyuanCity]
	id := strings.TrimSpace(r.ID)
	row := taoyuanTurnaroundRow{SubRouteUID: prefix + id, IsCircular: r.IsCircular == "1"}
	if back := strings.TrimSpace(r.BackStopID); back != "" {
		row.BackStopUID = prefix + back
	}
	return row, id != ""
}

func dumpTaoyuanTurnarounds(ctx context.Context, updateTime string, rows []taoyuanTurnaroundRow) error {
	// A slice of flat string/bool structs always encodes.
	body, _ := json.Marshal(rows)
	cycle, err := raw.NewLandingCycle()
	if err != nil {
		return err
	}
	target := raw.Target{Table: _taoyuanRouteTable, PartCol: "city", PartVal: _taoyuanCity}
	return raw.Dump(ctx, target, "taoyuanroute:"+updateTime, cycle, body)
}

// readTurnarounds attaches the landed turnaround stops to a Taoyuan snapshot.
// They are an enrichment on their own landing cycle: a missing or stale
// landing leaves the loops as TDX publishes them instead of failing the city.
func (b *busSnapshotBuilder) readTurnarounds() error {
	if b.snapshot.city != _taoyuanCity {
		return nil
	}
	turnarounds, err := b.loadTurnarounds()
	if err != nil {
		zap.S().Warnw("skipped", "component", "bus_static", "action", "taoyuan_turnaround", "event", "skipped", "err", err)
		return nil
	}
	b.snapshot.turnarounds = turnarounds
	return nil
}

func (b *busSnapshotBuilder) loadTurnarounds() (map[string]string, error) {
	body, _, err := readBusRawDataset(b.ctx, b.source, _taoyuanCity, _taoyuanRouteTable)
	if err != nil {
		return nil, err
	}
	return decodeTurnarounds(body)
}

func decodeTurnarounds(body []byte) (map[string]string, error) {
	var rows []taoyuanTurnaroundRow
	if err := json.Unmarshal(body, &rows); err != nil {
		return nil, _oops.Wrapf(err, "decode %s", _taoyuanRouteTable)
	}
	out := make(map[string]string, len(rows))
	for _, r := range rows {
		if r.BackStopUID != "" {
			out[r.SubRouteUID] = r.BackStopUID
		}
	}
	return out, nil
}

// turnaroundSequence is the StopSequence at which a single-direction subroute
// turns back, or 0 when it should be served as TDX publishes it: no
// turnaround, a real second direction, or a stop that is not exactly once an
// interior stop of the list.
func turnaroundSequence(sub *models.BusSubroute, backStopUID string) int32 {
	dir0, ok := sub.Directions[0]
	if !ok || len(sub.Directions) != 1 {
		return 0
	}
	return interiorSequence(dir0.Stops, backStopUID)
}

func interiorSequence(stops []*models.BusStop, uid string) int32 {
	at := soleStopIndex(stops, uid)
	if at <= 0 || at >= len(stops)-1 {
		return 0
	}
	return stops[at].StopSequence
}

// soleStopIndex is the index of the only stop with uid, or -1 when there is
// none or more than one.
func soleStopIndex(stops []*models.BusStop, uid string) int {
	at := -1
	for i, s := range stops {
		if s.StopUID == uid {
			at = soleIndex(at, i)
		}
	}
	return at
}

func soleIndex(seen, i int) int {
	if seen == -1 {
		return i
	}
	return -2
}

// splitAtTurnaround returns the rider-facing view of a loop: direction 0 runs
// out to the turnaround and direction 1 back from it, the turnaround stop
// closing one and opening the other. Stops keep their TDX StopSequence so live
// estimates, fare sections and the daily timetable still key onto them.
func splitAtTurnaround(sub *models.BusSubroute, seq int32) *models.BusSubroute {
	view := proto.Clone(sub).(*models.BusSubroute)
	loop := view.Directions[0]
	cut := slices.IndexFunc(loop.Stops, func(s *models.BusStop) bool { return s.StopSequence == seq })
	turn := loop.Stops[cut]
	out, back := splitLineString(loop.Geometry, turn.PositionLon, turn.PositionLat)
	ret := &models.Direction{
		DepartureStopName:   turn.StopName,
		DestinationStopName: loop.DestinationStopName,
		Geometry:            back,
		Stops:               loop.Stops[cut:],
		Schedules:           headwaySchedules(loop.Schedules),
	}
	loop.DestinationStopName = turn.StopName
	loop.Geometry = out
	loop.Stops = loop.Stops[:cut+1]
	view.Directions[1] = ret
	return view
}

// headwaySchedules keeps the frequency windows, which hold for both halves of
// the loop. Fixed timetable entries are origin departure times and would be
// wrong at the turnaround.
func headwaySchedules(in []*models.Bus_Schedule) []*models.Bus_Schedule {
	var out []*models.Bus_Schedule
	for _, s := range in {
		if !s.IsTimetable {
			out = append(out, s)
		}
	}
	return out
}

// splitLineString cuts a WKT LINESTRING at the vertex nearest (lon, lat), both
// halves sharing that vertex. Anything else is returned whole for both halves.
func splitLineString(wkt string, lon, lat float64) (string, string) {
	points := lineStringPoints(wkt)
	best := nearestPoint(points, lon, lat)
	if best <= 0 || best >= len(points)-1 {
		return wkt, wkt
	}
	return lineString(points[:best+1]), lineString(points[best:])
}

const _lineStringHead = "LINESTRING("

// lineStringPoints is the "x y" points of a WKT LINESTRING, nil for any other
// geometry.
func lineStringPoints(wkt string) []string {
	body, ok := strings.CutPrefix(wkt, _lineStringHead)
	body, closed := strings.CutSuffix(body, ")")
	if !ok || !closed {
		return nil
	}
	return strings.Split(body, ",")
}

func lineString(points []string) string {
	return _lineStringHead + strings.Join(points, ",") + ")"
}

// nearestPoint is the index of the WKT "x y" point nearest (lon, lat), or -1
// when any point does not parse.
func nearestPoint(points []string, lon, lat float64) int {
	dists := make([]float64, 0, len(points))
	for _, p := range points {
		var x, y float64
		if _, err := fmt.Sscan(p, &x, &y); err != nil {
			return -1
		}
		dists = append(dists, (x-lon)*(x-lon)+(y-lat)*(y-lat))
	}
	if len(dists) == 0 {
		return -1
	}
	return slices.Index(dists, slices.Min(dists))
}
