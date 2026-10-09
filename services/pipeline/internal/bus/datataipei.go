package bus

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
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

// 車牌號碼
// 附屬路線 id

// dataTaipeiEvent is one GetBusEvent element: a vehicle entering or leaving a
// stop. CarOnStop is "1" while the vehicle is at the stop and "0" once it has
// pulled out, so only the former places a bus anywhere.

type dataTaipeiFeed struct {
	client *resty.Client
	prefix string
	city   string

	mu   sync.Mutex
	etag map[string]string
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

// dataTaipeiCrowdLevel maps the feed's 0/1/2 banding onto the wire enum, which
// reserves its own zero for "no reading". A null Level, or a band the feed has
// not documented, reports false and leaves the vehicle unlabelled.

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

// etaSource is a live ETA feed that replaces TDX's for a city rather than
// overlaying it, the way vehicleSource's positions do. A nil map entry (or a
// city missing from it) leaves that city on TDX.

// estimates fetches GetEstimateTime and returns it as TDX-shaped ETA rows.

// dataTaipeiRawEstimates converts the feed onto the TDX ETA shape the ETA job
// already consumes. A row whose EstimateTime does not parse as one of the
// documented values is dropped rather than guessed at.
