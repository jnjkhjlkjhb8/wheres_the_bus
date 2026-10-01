package mrt

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

const _trtcAPIBase = "https://api.metro.taipei/metroapi/"

// _trtcClient is shared across ticks for connection reuse; per-tick deadlines
// come from the live runner's context.
var _trtcClient = resty.New().
	SetBaseURL(_trtcAPIBase).
	SetHeader("Content-Type", "application/soap+xml; charset=utf-8")

// TrtcTrack is one getTrackInfo element: the nearest train approaching a
// station toward a destination. Names only — no StationID or LineID, and
// TrainNumber is always empty on the Wenhu line.
type TrtcTrack struct {
	TrainNumber     string `json:"TrainNumber"`
	StationName     string `json:"StationName"`
	DestinationName string `json:"DestinationName"`
	CountDown       string `json:"CountDown"`
	NowDateTime     string `json:"NowDateTime"`
}

// trtcWeightEx is one getCarWeightByInfoEx element: a high-capacity-line
// train's six-car congestion at its current station.
type trtcWeightEx struct {
	TrainNumber string `json:"TrainNumber"`
	CN1         string `json:"CN1"`
	StationID   string `json:"StationID"`
	Cart1L      string `json:"Cart1L"`
	Cart2L      string `json:"Cart2L"`
	Cart3L      string `json:"Cart3L"`
	Cart4L      string `json:"Cart4L"`
	Cart5L      string `json:"Cart5L"`
	Cart6L      string `json:"Cart6L"`
}

// trtcWeightBR is one getCarWeightBRInfo element: a Wenhu-line train's four-car
// congestion at its current station. Its TrainNumber is a paired-car label
// ("7,26") that never appears in getTrackInfo, so pairing uses station+direction.
type trtcWeightBR struct {
	CN1       string `json:"CN1"`
	StationID string `json:"StationID"`
	DU        string `json:"DU"`
	Car1      string `json:"Car1"`
	Car2      string `json:"Car2"`
	Car3      string `json:"Car3"`
	Car4      string `json:"Car4"`
}

// TrtcAliases absorbs known misspellings in the official feed before station
// lookup. Extend as new dirty names surface in resolve-failure logs.
var TrtcAliases = map[string]string{
	"港漧":   "港墘",
	"松山機楊": "松山機場",
}

// parseTrtcCountdown maps the official CountDown string onto the EstimateTime
// seconds contract the app already renders: "mm:ss" → seconds, "列車進站" → 0.
// Anything else ("資料擷取中", garbage) carries no information — not ok.
func parseTrtcCountdown(s string) (int32, bool) {
	if s == "列車進站" {
		return 0, true
	}
	total, ok := ParseMMSS(s)
	if !ok {
		return 0, false
	}
	return int32(total), true
}

// ParseMMSS parses a "mm:ss" countdown into total seconds. Minutes are
// unbounded (the feed publishes three-digit waits); seconds must be 0..59.
func ParseMMSS(s string) (int, bool) {
	minutes, seconds, found := strings.Cut(s, ":")
	if !found {
		return 0, false
	}
	mi, errMin := strconv.Atoi(minutes)
	si, errSec := strconv.Atoi(seconds)
	if errMin != nil || errSec != nil {
		return 0, false
	}
	if mi < 0 || si < 0 || si > 59 {
		return 0, false
	}
	return mi*60 + si, true
}

// TrtcLinePrefix returns the line letters of a station ID ("BL12" → "BL").
func TrtcLinePrefix(stationID string) string {
	for i, r := range stationID {
		if r >= '0' && r <= '9' {
			return stationID[:i]
		}
	}
	return stationID
}

// _trtcTrainLine maps a getTrackInfo TrainNumber's hundreds digit to its line;
// Wenhu trains never carry numbers.
var _trtcTrainLine = map[byte]string{'1': "R", '2': "BL", '3': "G", '4': "O"}

func resolveTrtcStation(names map[string][]string, station, dest, trainNumber string) (stationID, destID, line string, ok bool) {
	sIDs := trtcLookup(names, station)
	dIDs := trtcLookup(names, dest)
	type pair struct{ s, d string }
	byLine := map[string]pair{}
	lines := []string{}
	for _, s := range sIDs {
		for _, d := range dIDs {
			if l := TrtcLinePrefix(s); l == TrtcLinePrefix(d) {
				if _, seen := byLine[l]; !seen {
					byLine[l] = pair{s, d}
					lines = append(lines, l)
				}
			}
		}
	}
	switch {
	case len(lines) == 0:
		return "", "", "", false
	case len(lines) == 1:
		line = lines[0]
	case trainNumber != "" && _trtcTrainLine[trainNumber[0]] != "" && byLine[_trtcTrainLine[trainNumber[0]]] != pair{}:
		line = _trtcTrainLine[trainNumber[0]]
	case byLine["BR"] != pair{}:
		line = "BR"
	default:
		return "", "", "", false
	}
	p := byLine[line]
	return p.s, p.d, line, true
}

// trtcLookup tries the raw name, its alias, then the name without the 站
// suffix (the feed writes 動物園站; mrt_station stores 動物園 but also names
// that legitimately end in 站, like 台北車站).
func trtcLookup(names map[string][]string, name string) []string {
	if a, ok := TrtcAliases[name]; ok {
		name = a
	}
	if ids, ok := names[name]; ok {
		return ids
	}
	return names[strings.TrimSuffix(name, "站")]
}

func trtcStationNames(ctx context.Context, db *pgxpool.Pool) (map[string][]string, error) {
	rows, err := db.Query(ctx, `SELECT station_id, name FROM mrt_station WHERE system IN ('TRTC', 'NTMC')`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	names := map[string][]string{}
	for rows.Next() {
		var id, name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		if a, ok := TrtcAliases[name]; ok {
			name = a
		}
		names[name] = append(names[name], id)
	}
	return names, rows.Err()
}

// trtcBRNextKey keys the Wenhu congestion map by the station a train reaches
// next: BR station numbers are sequential, so a train at BR16 going up is the
// arrival at BR17. up means toward 南港展覽館 (increasing numbers).
func trtcBRNextKey(stationID string, up bool) string {
	n, err := strconv.Atoi(strings.TrimPrefix(stationID, "BR"))
	if err != nil {
		return ""
	}
	if up {
		n++
	} else {
		n--
	}
	return fmt.Sprintf("BR%02d|%t", n, up)
}

func trtcSOAP(ctx context.Context, page, method, user, pass string) ([]byte, error) {
	esc := func(s string) string {
		var b strings.Builder
		_ = xml.EscapeText(&b, []byte(s))
		return b.String()
	}
	body := fmt.Sprintf(`<?xml version="1.0" encoding="utf-8"?><soap12:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap12="http://www.w3.org/2003/05/soap-envelope"><soap12:Body><%s xmlns="http://tempuri.org/"><userName>%s</userName><passWord>%s</passWord></%s></soap12:Body></soap12:Envelope>`,
		method, esc(user), esc(pass), method)
	resp, err := _trtcClient.R().
		SetContext(ctx).
		SetBody(body).
		Post(page + ".asmx")
	if err != nil {
		return nil, err
	}
	raw := resp.Body()
	if resp.StatusCode() != http.StatusOK {
		return nil, _oops.With("method", method).With("status_code", resp.StatusCode()).Errorf("status")
	}
	history.ArchiveLivePayload(history.DatasetMRT, method, time.Now(), raw)
	start := strings.IndexByte(string(raw), '[')
	end := strings.LastIndexByte(string(raw), ']')
	if start < 0 || end <= start {
		return nil, _oops.With("method", method).Errorf("no JSON array in response")
	}
	return raw[start : end+1], nil
}

// TrtcEta is the 15s live job. Congestion fetch failures degrade to
// countdown-only arrivals; only the arrival feed itself is fatal.
func TrtcEta(ctx context.Context, sink pipeline.LiveSink, db *pgxpool.Pool) error {
	user, pass := os.Getenv("TRTC_USERNAME"), os.Getenv("TRTC_PASSWORD")
	if user == "" || pass == "" {
		zap.S().Warnw("skip",
			"component", "trtc_eta",
			"action", "trtc_eta",
			"event", "skip",
			"reason", "no_credentials",
		)
		return nil
	}
	zap.S().Infow("start", "component", "trtc_eta", "action", "trtc_eta", "event", "start")

	var (
		wg       sync.WaitGroup
		tracks   []TrtcTrack
		exRows   []trtcWeightEx
		brRows   []trtcWeightBR
		trackErr error
	)
	fetch := func(page, method string, into any, fatal *error) {
		defer wg.Done()
		raw, err := trtcSOAP(ctx, page, method, user, pass)
		if err == nil {
			err = json.Unmarshal(raw, into)
		}
		if err != nil {
			if fatal != nil {
				*fatal = _oops.With("method", method).Wrapf(err, "TRTC call")
				return
			}
			zap.S().Warnw("weight fetch failed",
				"component", "trtc_eta",
				"action", "trtc_eta",
				"event", "weight_fetch_failed",
				"method", method,
				"err", err,
			)
		}
	}
	wg.Add(3)
	go fetch("TrackInfo", "getTrackInfo", &tracks, &trackErr)
	go fetch("CarWeight", "getCarWeightByInfoEx", &exRows, nil)
	go fetch("CarWeightBR", "getCarWeightBRInfo", &brRows, nil)
	wg.Wait()
	if trackErr != nil {
		return trackErr
	}

	names, err := trtcStationNames(ctx, db)
	if err != nil {
		return _oops.Wrapf(err, "trtc station names")
	}
	windows := ServiceWindows(ctx, db)
	return TrtcPublish(ctx, sink, names, windows, time.Now().In(pipeline.Taipei), tracks, exRows, brRows)
}

// trtcPublish is the pure pairing+publish core: it maps arrivals to Redis
// writes, attaching congestion (congestion pairing, CONTEXT.md). Split from
// TrtcEta so tests drive it with fixture rows instead of the SOAP endpoints.
func TrtcPublish(ctx context.Context, sink pipeline.LiveSink, names map[string][]string, windows map[string][]ServiceWindow, now time.Time, tracks []TrtcTrack, exRows []trtcWeightEx, brRows []trtcWeightBR) error {
	exByTrain := make(map[string]trtcWeightEx, len(exRows))
	for _, w := range exRows {
		exByTrain[w.TrainNumber] = w
	}
	brByNext := make(map[string]trtcWeightBR, len(brRows))
	for _, w := range brRows {
		if k := trtcBRNextKey(w.StationID, w.DU == "上行"); k != "" {
			brByNext[k] = w
		}
	}

	pipe := sink.Pipe()
	ownedKeys := make([]string, 0, len(tracks))
	var dropped, filtered int
	for _, t := range tracks {
		secs, ok := parseTrtcCountdown(t.CountDown)
		if !ok {
			continue
		}
		stationID, destID, line, ok := resolveTrtcStation(names, t.StationName, t.DestinationName, t.TrainNumber)
		if !ok {
			dropped++
			zap.S().Warnw("resolve failed",
				"component", "trtc_eta",
				"action", "trtc_eta",
				"event", "resolve_failed",
				"station", t.StationName,
				"dest", t.DestinationName,
			)
			continue
		}
		if !InService(windows, WindowKey("TRTC", stationID, line, destID), now) {
			filtered++
			continue
		}
		raw := &models.MrtLive{
			LineID:                 line,
			StationID:              stationID,
			StationName:            strings.TrimSuffix(t.StationName, "站"),
			System:                 "TRTC",
			DestinationStaionID:    destID,
			DestinationStationName: strings.TrimSuffix(t.DestinationName, "站"),
			EstimateTime:           secs,
			CountDown:              t.CountDown,
			NowDateTime:            t.NowDateTime,
			TrainNumber:            t.TrainNumber,
		}
		if w, ok := exByTrain[t.TrainNumber]; ok && t.TrainNumber != "" {
			raw.CN1 = w.CN1
			raw.Weight = &models.CartWeight{
				Cart1L: w.Cart1L, Cart2L: w.Cart2L, Cart3L: w.Cart3L,
				Cart4L: w.Cart4L, Cart5L: w.Cart5L, Cart6L: w.Cart6L,
			}
		} else if line == "BR" {
			up := destID > stationID // BR IDs are zero-padded, so string order is numeric order
			if w, ok := brByNext[fmt.Sprintf("%s|%t", stationID, up)]; ok {
				raw.CN1 = w.CN1
				raw.Weight = &models.CartWeight{
					Cart1L: w.Car1, Cart2L: w.Car2, Cart3L: w.Car3, Cart4L: w.Car4,
				}
			}
		}
		pb, err := proto.Marshal(raw)
		if err != nil {
			return err
		}
		key := shared.MrtLiveKey("TRTC", stationID, line, destID)
		pipe.Set(key, pb, pipeline.MrtLiveTTL)
		ownedKeys = append(ownedKeys, key)
		pipe.Publish(shared.MrtLiveChannel("TRTC", stationID), string(pb))
	}
	pipe.ReplaceOwnedKeys(shared.LiveOwnedKeysKey("mrt", "TRTC"), ownedKeys, pipeline.OwnedKeysTTL)
	if err := pipe.Exec(ctx); err != nil {
		return _oops.Wrapf(err, "publish TRTC live board")
	}
	zap.S().Infow("complete",
		"component", "trtc_eta",
		"action", "trtc_eta",
		"event", "complete",
		"arrivals", len(ownedKeys),
		"dropped", dropped,
		"out_of_service", filtered,
	)
	return nil
}
