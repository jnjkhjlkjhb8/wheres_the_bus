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
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
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

// parseTrtcCountdown maps the official CountDown string onto the EstimateTime
// seconds contract the app already renders: "mm:ss" → seconds, "列車進站" → 0.
// Anything else ("資料擷取中", garbage) carries no information — not ok.
func parseTrtcCountdown(s string) (int32, bool) {
	if s == "列車進站" {
		return 0, true
	}
	total, ok := shared.ParseMMSS(s)
	if !ok {
		return 0, false
	}
	return int32(total), true
}

// _trtcTrainLine maps a getTrackInfo TrainNumber's hundreds digit to its line;
// Wenhu trains never carry numbers.
var _trtcTrainLine = map[byte]string{'1': "R", '2': "BL", '3': "G", '4': "O"}

type trtcStationPair struct{ s, d string }

func resolveTrtcStation(names map[string][]string, station, dest, trainNumber string) (stationID, destID, line string, ok bool) {
	byLine, lines := matchTrtcStations(trtcLookup(names, station), trtcLookup(names, dest))
	line, ok = chooseTrtcLine(byLine, lines, trainNumber)
	if !ok {
		return "", "", "", false
	}
	p := byLine[line]
	return p.s, p.d, line, true
}

func matchTrtcStations(sIDs, dIDs []string) (map[string]trtcStationPair, []string) {
	byLine := map[string]trtcStationPair{}
	lines := []string{}
	for _, s := range sIDs {
		for _, d := range dIDs {
			lines = appendTrtcStationPair(byLine, lines, s, d)
		}
	}
	return byLine, lines
}

func appendTrtcStationPair(byLine map[string]trtcStationPair, lines []string, station, dest string) []string {
	line := shared.TrtcLinePrefix(station)
	if line != shared.TrtcLinePrefix(dest) {
		return lines
	}
	if _, seen := byLine[line]; seen {
		return lines
	}
	byLine[line] = trtcStationPair{station, dest}
	return append(lines, line)
}

func chooseTrtcLine(byLine map[string]trtcStationPair, lines []string, trainNumber string) (string, bool) {
	hint, hasHint := matchingTrtcTrainLine(byLine, trainNumber)
	if len(lines) == 0 {
		return "", false
	}
	if len(lines) == 1 {
		return lines[0], true
	}
	return preferredTrtcLine(byLine, hint, hasHint)
}

func preferredTrtcLine(byLine map[string]trtcStationPair, hint string, hasHint bool) (string, bool) {
	if hasHint {
		return hint, true
	}
	if byLine["BR"] != (trtcStationPair{}) {
		return "BR", true
	}
	return "", false
}

func matchingTrtcTrainLine(byLine map[string]trtcStationPair, trainNumber string) (string, bool) {
	if trainNumber == "" {
		return "", false
	}
	line := _trtcTrainLine[trainNumber[0]]
	return line, line != "" && byLine[line] != (trtcStationPair{})
}

// trtcLookup tries the raw name, its alias, then the name without the 站
// suffix (the feed writes 動物園站; mrt_station stores 動物園 but also names
// that legitimately end in 站, like 台北車站).
func trtcLookup(names map[string][]string, name string) []string {
	if a, ok := shared.TrtcAliases[name]; ok {
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
	return readTrtcStationNames(rows)
}

func readTrtcStationNames(rows pgx.Rows) (map[string][]string, error) {
	names := map[string][]string{}
	for rows.Next() {
		var id, name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		name = trtcStationAlias(name)
		names[name] = append(names[name], id)
	}
	return names, rows.Err()
}

func trtcStationAlias(name string) string {
	if alias, ok := shared.TrtcAliases[name]; ok {
		return alias
	}
	return name
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
	return trtcJSONArray(raw, method)
}

func trtcJSONArray(raw []byte, method string) ([]byte, error) {
	start := strings.IndexByte(string(raw), '[')
	end := strings.LastIndexByte(string(raw), ']')
	if start < 0 || end <= start {
		return nil, _oops.With("method", method).Errorf("no JSON array in response")
	}
	return raw[start : end+1], nil
}

// TrtcEta is the 15s live job. Congestion fetch failures degrade to
// countdown-only arrivals; only the arrival feed itself is fatal.
type trtcFeedSnapshot struct {
	tracks []TrtcTrack
	exRows []trtcWeightEx
	brRows []trtcWeightBR
}

func TrtcEta(ctx context.Context, sink pipeline.LiveSink, db *pgxpool.Pool) error {
	user, pass := os.Getenv("TRTC_USERNAME"), os.Getenv("TRTC_PASSWORD")
	if missingTrtcCredentials(user, pass) {
		zap.S().Warnw("skip", "component", "trtc_eta", "action", "trtc_eta", "event", "skip", "reason", "no_credentials")
		return nil
	}
	zap.S().Infow("start", "component", "trtc_eta", "action", "trtc_eta", "event", "start")
	feeds, err := fetchTrtcFeeds(ctx, user, pass)
	if err != nil {
		return err
	}
	return publishTrtcFeeds(ctx, sink, db, feeds)
}

func missingTrtcCredentials(user, pass string) bool { return user == "" || pass == "" }

func fetchTrtcFeeds(ctx context.Context, user, pass string) (trtcFeedSnapshot, error) {
	var feeds trtcFeedSnapshot
	var trackErr error
	var wg sync.WaitGroup
	fetch := func(page, method string, into any, fatal *error) {
		defer wg.Done()
		fetchTrtcFeed(ctx, page, method, user, pass, into, fatal)
	}
	wg.Add(3)
	go fetch("TrackInfo", "getTrackInfo", &feeds.tracks, &trackErr)
	go fetch("CarWeight", "getCarWeightByInfoEx", &feeds.exRows, nil)
	go fetch("CarWeightBR", "getCarWeightBRInfo", &feeds.brRows, nil)
	wg.Wait()
	return feeds, trackErr
}

func fetchTrtcFeed(ctx context.Context, page, method, user, pass string, into any, fatal *error) {
	err := decodeTrtcFeed(ctx, page, method, user, pass, into)
	if err == nil {
		return
	}
	if fatal != nil {
		*fatal = _oops.With("method", method).Wrapf(err, "TRTC call")
		return
	}
	zap.S().Warnw("weight fetch failed", "component", "trtc_eta", "action", "trtc_eta", "event", "weight_fetch_failed", "method", method, "err", err)
}

func decodeTrtcFeed(ctx context.Context, page, method, user, pass string, into any) error {
	raw, err := trtcSOAP(ctx, page, method, user, pass)
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, into)
}

func publishTrtcFeeds(ctx context.Context, sink pipeline.LiveSink, db *pgxpool.Pool, feeds trtcFeedSnapshot) error {
	names, err := trtcStationNames(ctx, db)
	if err != nil {
		return _oops.Wrapf(err, "trtc station names")
	}
	return TrtcPublish(ctx, sink, names, ServiceWindows(ctx, db), time.Now().In(pipeline.Taipei), feeds.tracks, feeds.exRows, feeds.brRows)
}

// trtcPublish is the pure pairing+publish core: it maps arrivals to Redis
// writes, attaching congestion (congestion pairing, CONTEXT.md). Split from
// TrtcEta so tests drive it with fixture rows instead of the SOAP endpoints.
type trtcPublishState struct {
	pipe              pipeline.LivePipe
	names             map[string][]string
	windows           map[string][]ServiceWindow
	now               time.Time
	exByTrain         map[string]trtcWeightEx
	brByNext          map[string]trtcWeightBR
	ownedKeys         []string
	dropped, filtered int
}

func TrtcPublish(ctx context.Context, sink pipeline.LiveSink, names map[string][]string, windows map[string][]ServiceWindow, now time.Time, tracks []TrtcTrack, exRows []trtcWeightEx, brRows []trtcWeightBR) error {
	exByTrain, brByNext := indexTrtcWeights(exRows, brRows)
	state := trtcPublishState{pipe: sink.Pipe(), names: names, windows: windows, now: now, exByTrain: exByTrain, brByNext: brByNext, ownedKeys: make([]string, 0, len(tracks))}
	for _, track := range tracks {
		if err := state.publishTrack(track); err != nil {
			return err
		}
	}
	return state.commit(ctx)
}

func (s *trtcPublishState) publishTrack(track TrtcTrack) error {
	secs, ok := parseTrtcCountdown(track.CountDown)
	if !ok {
		return nil
	}
	raw := s.resolveArrival(track, secs)
	if raw == nil {
		return nil
	}
	return s.queueArrival(raw)
}

func (s *trtcPublishState) resolveArrival(track TrtcTrack, secs int32) *models.MrtLive {
	stationID, destID, line, ok := resolveTrtcStation(s.names, track.StationName, track.DestinationName, track.TrainNumber)
	if !ok {
		s.dropped++
		zap.S().Warnw("resolve failed", "component", "trtc_eta", "action", "trtc_eta", "event", "resolve_failed", "station", track.StationName, "dest", track.DestinationName)
		return nil
	}
	if !InService(s.windows, WindowKey("TRTC", stationID, line, destID), s.now) {
		s.filtered++
		return nil
	}
	return &models.MrtLive{LineID: line, StationID: stationID, StationName: strings.TrimSuffix(track.StationName, "站"), System: "TRTC", DestinationStaionID: destID, DestinationStationName: strings.TrimSuffix(track.DestinationName, "站"), EstimateTime: secs, CountDown: track.CountDown, NowDateTime: track.NowDateTime, TrainNumber: track.TrainNumber}
}

func (s *trtcPublishState) queueArrival(raw *models.MrtLive) error {
	applyTrtcWeights(raw, s.exByTrain, s.brByNext)
	pb, err := proto.Marshal(raw)
	if err != nil {
		return err
	}
	key := shared.MrtLiveKey("TRTC", raw.StationID, raw.LineID, raw.DestinationStaionID)
	s.pipe.Set(key, pb, pipeline.MrtLiveTTL)
	s.ownedKeys = append(s.ownedKeys, key)
	s.pipe.Publish(shared.MrtLiveChannel("TRTC", raw.StationID), string(pb))
	return nil
}

func (s *trtcPublishState) commit(ctx context.Context) error {
	s.pipe.ReplaceOwnedKeys(shared.LiveOwnedKeysKey("mrt", "TRTC"), s.ownedKeys, pipeline.OwnedKeysTTL)
	if err := s.pipe.Exec(ctx); err != nil {
		return _oops.Wrapf(err, "publish TRTC live board")
	}
	zap.S().Infow("complete", "component", "trtc_eta", "action", "trtc_eta", "event", "complete", "arrivals", len(s.ownedKeys), "dropped", s.dropped, "out_of_service", s.filtered)
	return nil
}

func indexTrtcWeights(exRows []trtcWeightEx, brRows []trtcWeightBR) (map[string]trtcWeightEx, map[string]trtcWeightBR) {
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

	return exByTrain, brByNext
}

func applyTrtcWeights(raw *models.MrtLive, exByTrain map[string]trtcWeightEx, brByNext map[string]trtcWeightBR) {
	if applyTrtcExpressWeight(raw, exByTrain) {
		return
	}
	if raw.LineID == "BR" {
		applyTrtcBRWeight(raw, brByNext)
	}
}

func applyTrtcExpressWeight(raw *models.MrtLive, exByTrain map[string]trtcWeightEx) bool {
	if w, ok := exByTrain[raw.TrainNumber]; ok && raw.TrainNumber != "" {
		raw.CN1 = w.CN1
		raw.Weight = &models.CartWeight{
			Cart1L: w.Cart1L, Cart2L: w.Cart2L, Cart3L: w.Cart3L,
			Cart4L: w.Cart4L, Cart5L: w.Cart5L, Cart6L: w.Cart6L,
		}
		return true
	}
	return false
}

func applyTrtcBRWeight(raw *models.MrtLive, brByNext map[string]trtcWeightBR) {
	up := raw.DestinationStaionID > raw.StationID // BR IDs are zero-padded, so string order is numeric order
	if w, ok := brByNext[fmt.Sprintf("%s|%t", raw.StationID, up)]; ok {
		raw.CN1 = w.CN1
		raw.Weight = &models.CartWeight{
			Cart1L: w.Car1, Cart2L: w.Car2, Cart3L: w.Car3, Cart4L: w.Car4,
		}
	}
}
