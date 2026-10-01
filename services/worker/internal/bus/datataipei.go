package bus

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/history"
	"go.uber.org/zap"
)

const _dataTaipeiBlobBase = "https://tcgbusfs.blob.core.windows.net/blobbus/"
const _dataTaipeiNTPCBusBase = "https://tcgbusfs.blob.core.windows.net/ntpcbus/"

const _dataTaipeiUIDPrefix = "TPE"

var _dataTaipeiDynamicCities = map[string]struct {
	base   string
	prefix string
}{
	"Taipei":    {base: _dataTaipeiBlobBase, prefix: _dataTaipeiUIDPrefix},
	"NewTaipei": {base: _dataTaipeiNTPCBusBase, prefix: "NWT"},
}

const _dataTaipeiTimeout = 10 * time.Second

// dataTaipeiBus is one GetBusData element: a vehicle's current position.
// Every numeric is delivered as a string, including the coordinates.
type dataTaipeiBus struct {
	BusID      string `json:"BusID"`   // 車牌號碼
	RouteID    string `json:"RouteID"` // 附屬路線 id
	GoBack     string `json:"GoBack"`
	Longitude  string `json:"Longitude"`
	Latitude   string `json:"Latitude"`
	Speed      string `json:"Speed"`
	Azimuth    string `json:"Azimuth"`
	DutyStatus string `json:"DutyStatus"`
	BusStatus  string `json:"BusStatus"`
	DataTime   string `json:"DataTime"`
}

// dataTaipeiEvent is one GetBusEvent element: a vehicle entering or leaving a
// stop. CarOnStop is "1" while the vehicle is at the stop and "0" once it has
// pulled out, so only the former places a bus anywhere.
type dataTaipeiEvent struct {
	BusID     string `json:"BusID"`
	StopID    string `json:"StopID"`
	CarOnStop string `json:"CarOnStop"`
}

type dataTaipeiSeat struct {
	BusID string `json:"BusID"`
	Level *int   `json:"Level"`
}

type dataTaipeiFeed struct {
	client *resty.Client
	prefix string
	city   string

	mu           sync.Mutex
	etag         map[string]string
	buses        []dataTaipeiBus
	events       []dataTaipeiEvent
	seats        []dataTaipeiSeat
	estimateRows []dataTaipeiEstimate
}

// _dataTaipeiClients are shared across ticks for connection reuse, the same
// shape trtcClient has, one per dataTaipeiDynamicCities entry; per-tick
// deadlines come from the live runner's context.
var _dataTaipeiClients = func() map[string]*resty.Client {
	clients := make(map[string]*resty.Client, len(_dataTaipeiDynamicCities))
	for city, cfg := range _dataTaipeiDynamicCities {
		clients[city] = resty.New().SetBaseURL(cfg.base).SetTimeout(_dataTaipeiTimeout)
	}
	return clients
}()

var _ vehicleSource = (*dataTaipeiFeed)(nil)
var _ etaSource = (*dataTaipeiFeed)(nil)

// NewDataTaipeiFeed builds a feed scoped to one dataTaipeiDynamicCities entry.
// Callers only ever pass a listed city (Eta, ingestor.go's daily timetable
// landing), so an unlisted one is not defended against here.
func NewDataTaipeiFeed(city string) *dataTaipeiFeed {
	cfg := _dataTaipeiDynamicCities[city]
	return &dataTaipeiFeed{
		client: _dataTaipeiClients[city],
		prefix: cfg.prefix,
		city:   city,
		etag:   make(map[string]string, 4),
	}
}

// getEnvelope fetches one blob, decoding the whole document into out only when
// the body changed. It reports whether anything was decoded, so the caller can
// keep its last copy.
func (f *dataTaipeiFeed) getEnvelope(ctx context.Context, name string, out any) (bool, error) {
	f.mu.Lock()
	prior := f.etag[name]
	f.mu.Unlock()
	req := f.client.R().SetContext(ctx)
	if prior != "" {
		req.SetHeader("If-None-Match", prior)
	}
	resp, err := req.Get(name + ".gz")
	if err != nil {
		return false, err
	}
	if resp.StatusCode() == http.StatusNotModified {
		return false, nil
	}
	if resp.StatusCode() != http.StatusOK {
		return false, _oops.With("name", name).With("status_code", resp.StatusCode()).Errorf("HTTP")
	}
	body, err := gunzipIfCompressed(resp.Body())
	if err != nil {
		return false, _oops.With("dataset", name).Wrapf(err, "Data.taipei resource")
	}
	if history.IsLiveDataTaipeiBlob(name) {
		history.ArchiveLivePayload(history.DatasetBusFast, f.city+"/"+name, time.Now(), body)
	}
	if err := json.Unmarshal(body, out); err != nil {
		return false, _oops.With("dataset", name).Wrapf(err, "Data.taipei resource")
	}
	f.mu.Lock()
	f.etag[name] = resp.Header().Get("ETag")
	f.mu.Unlock()
	return true, nil
}

// getRows fetches one of the blobs that wrap their rows in
// {"EssentialInfo": …, "BusInfo": [...]} and decodes the rows alone. The
// timetable blobs use their own envelope and go through getEnvelope instead.
func (f *dataTaipeiFeed) getRows(ctx context.Context, name string, out any) (bool, error) {
	var envelope struct {
		BusInfo json.RawMessage `json:"BusInfo"`
	}
	modified, err := f.getEnvelope(ctx, name, &envelope)
	if err != nil || !modified {
		return false, err
	}
	if err := json.Unmarshal(envelope.BusInfo, out); err != nil {
		return false, _oops.With("dataset", name).Wrapf(err, "Data.taipei resource")
	}
	return true, nil
}

func gunzipIfCompressed(body []byte) ([]byte, error) {
	if len(body) < 2 || body[0] != 0x1f || body[1] != 0x8b {
		return body, nil
	}
	zr, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer func() { _ = zr.Close() }()
	return io.ReadAll(zr)
}

// positions fetches both blobs and returns them as TDX-shaped position rows.
func (f *dataTaipeiFeed) positions(ctx context.Context) ([]busmodel.RawPosition, error) {
	var buses []dataTaipeiBus
	freshBuses, busErr := f.getRows(ctx, "GetBusData", &buses)
	var events []dataTaipeiEvent
	freshEvents, eventErr := f.getRows(ctx, "GetBusEvent", &events)
	var seats []dataTaipeiSeat
	freshSeats, seatErr := f.getRows(ctx, "BusSeatEvent", &seats)
	if err := errors.Join(busErr, eventErr, seatErr); err != nil {
		return nil, err
	}
	f.mu.Lock()
	if freshBuses {
		f.buses = buses
	}
	if freshEvents {
		f.events = events
	}
	if freshSeats {
		f.seats = seats
	}
	buses, events, seats = f.buses, f.events, f.seats
	f.mu.Unlock()
	return dataTaipeiRawPositions(f.prefix, buses, events, seats), nil
}

func dataTaipeiRawPositions(prefix string, buses []dataTaipeiBus, events []dataTaipeiEvent, seats []dataTaipeiSeat) []busmodel.RawPosition {
	atStop := make(map[string]string, len(events))
	for _, e := range events {
		if e.CarOnStop == "1" && e.StopID != "" {
			atStop[e.BusID] = prefix + e.StopID
		}
	}
	crowd := make(map[string]models.BusCrowdLevel, len(seats))
	for _, s := range seats {
		if level, ok := dataTaipeiCrowdLevel(s.Level); ok {
			crowd[s.BusID] = level
		}
	}
	out := make([]busmodel.RawPosition, 0, len(buses))
	for _, b := range buses {
		direction, ok := dataTaipeiDirection(b.GoBack)
		if !ok || b.RouteID == "" {
			continue
		}
		lon, lonErr := strconv.ParseFloat(b.Longitude, 64)
		lat, latErr := strconv.ParseFloat(b.Latitude, 64)
		if lonErr != nil || latErr != nil {
			continue
		}
		p := busmodel.RawPosition{
			PlateNumb:   b.BusID,
			SubRouteUID: prefix + b.RouteID,
			StopUID:     atStop[b.BusID],
			Direction:   direction,
			Azimuth:     dataTaipeiFloat(b.Azimuth),
			Speed:       dataTaipeiFloat(b.Speed),
			DutyStatus:  dataTaipeiUint8(b.DutyStatus),
			BusStatus:   dataTaipeiUint8(b.BusStatus),
			GPSTime:     b.DataTime,
			CrowdLevel:  crowd[b.BusID],
		}
		p.BusPosition.PositionLon = lon
		p.BusPosition.PositionLat = lat
		out = append(out, p)
	}
	return out
}

// dataTaipeiCrowdLevel maps the feed's 0/1/2 banding onto the wire enum, which
// reserves its own zero for "no reading". A null Level, or a band the feed has
// not documented, reports false and leaves the vehicle unlabelled.
func dataTaipeiCrowdLevel(level *int) (models.BusCrowdLevel, bool) {
	if level == nil {
		return models.BusCrowdLevel_BUS_CROWD_UNKNOWN, false
	}
	switch *level {
	case 0:
		return models.BusCrowdLevel_BUS_CROWD_COMFORTABLE, true
	case 1:
		return models.BusCrowdLevel_BUS_CROWD_NORMAL, true
	case 2:
		return models.BusCrowdLevel_BUS_CROWD_CROWDED, true
	default:
		return models.BusCrowdLevel_BUS_CROWD_UNKNOWN, false
	}
}

// dataTaipeiDirection maps GoBack onto the TDX Direction. "2" is the feed's
// 未知, which no canonical subroute can be derived from.
func dataTaipeiDirection(goBack string) (uint8, bool) {
	switch goBack {
	case "0":
		return 0, true
	case "1":
		return 1, true
	default:
		return 0, false
	}
}

func dataTaipeiFloat(s string) float64 {
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0
	}
	return v
}

func dataTaipeiUint8(s string) uint8 {
	v, err := strconv.Atoi(s)
	if err != nil || v < 0 || v > 255 {
		return 0
	}
	return uint8(v)
}

type dataTaipeiEstimate struct {
	RouteID      int    `json:"RouteID"`
	StopID       int    `json:"StopID"`
	EstimateTime string `json:"EstimateTime"`
	GoBack       string `json:"GoBack"`
}

// etaSource is a live ETA feed that replaces TDX's for a city rather than
// overlaying it, the way vehicleSource's positions do. A nil map entry (or a
// city missing from it) leaves that city on TDX.
type etaSource interface {
	estimates(context.Context) ([]busmodel.RawEstimated, error)
}

// estimates fetches GetEstimateTime and returns it as TDX-shaped ETA rows.
func (f *dataTaipeiFeed) estimates(ctx context.Context) ([]busmodel.RawEstimated, error) {
	var rows []dataTaipeiEstimate
	fresh, err := f.getRows(ctx, "GetEstimateTime", &rows)
	if err != nil {
		return nil, err
	}
	f.mu.Lock()
	if fresh {
		f.estimateRows = rows
	}
	rows = f.estimateRows
	f.mu.Unlock()
	return dataTaipeiRawEstimates(f.prefix, rows), nil
}

// dataTaipeiRawEstimates converts the feed onto the TDX ETA shape the ETA job
// already consumes. A row whose EstimateTime does not parse as one of the
// documented values is dropped rather than guessed at.
func dataTaipeiRawEstimates(prefix string, rows []dataTaipeiEstimate) []busmodel.RawEstimated {
	out := make([]busmodel.RawEstimated, 0, len(rows))
	for _, r := range rows {
		status, seconds, ok := dataTaipeiStopStatus(r.EstimateTime)
		if !ok {
			continue
		}
		out = append(out, busmodel.RawEstimated{
			StopUID:       fmt.Sprintf("%s%d", prefix, r.StopID),
			RouteUID:      fmt.Sprintf("%s%d", prefix, r.RouteID),
			Direction:     dataTaipeiEstimateDirection(r.GoBack),
			EstimatedTime: seconds,
			StopStatus:    status,
		})
	}
	return out
}

func dataTaipeiStopStatus(estimateTime string) (status uint8, seconds int32, ok bool) {
	v, err := strconv.Atoi(estimateTime)
	if err != nil {
		return 0, 0, false
	}
	if v > 0 {
		return 0, int32(v), true
	}
	switch v {
	case -1, -2, -3, -4:
		return uint8(-v), 0, true
	default:
		return 0, 0, false
	}
}

func dataTaipeiEstimateDirection(goBack string) uint8 {
	switch goBack {
	case "0":
		return 0
	case "1":
		return 1
	default:
		return _busEtaDirectionUnknown
	}
}

func mergeDataTaipeiPositions(tdx, dataTaipei []busmodel.RawPosition) []busmodel.RawPosition {
	if len(dataTaipei) == 0 {
		return tdx
	}
	covered := make(map[string]struct{}, len(dataTaipei))
	for _, p := range dataTaipei {
		covered[busPositionIdentity(p.SubRouteUID, p.Direction)] = struct{}{}
	}
	merged := make([]busmodel.RawPosition, 0, len(tdx)+len(dataTaipei))
	merged = append(merged, dataTaipei...)
	for _, p := range tdx {
		if _, ok := covered[busPositionIdentity(p.SubRouteUID, p.Direction)]; !ok {
			merged = append(merged, p)
		}
	}
	return merged
}

func (j *busLiveJob) overlayVehicles(ctx context.Context, city string, tdx []busmodel.RawPosition) []busmodel.RawPosition {
	feed, ok := j.vehicles[city]
	if !ok {
		return tdx
	}
	fresh, err := feed.positions(ctx)
	if err != nil {
		zap.S().Warnw("fetch failed; keeping TDX positions",
			"component", "datataipei",
			"action", "positions",
			"city", city,
			"err", err,
		)
		return tdx
	}
	return mergeDataTaipeiPositions(tdx, fresh)
}
