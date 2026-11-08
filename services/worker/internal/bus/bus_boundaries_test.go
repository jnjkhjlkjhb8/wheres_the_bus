package bus

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/predict"
)

type readErrorBusSink struct {
	captureLiveSink
	value string
	err   error
}

func (s *readErrorBusSink) GetString(context.Context, string) (string, error) { return s.value, s.err }

func TestBusFreshnessExactBoundariesAndFrozenThreshold(t *testing.T) {
	now := time.Date(2026, 10, 10, 10, 0, 0, 0, time.UTC)
	if !positionFresh(now.Add(-_busPositionMaxAge).Unix(), now) || positionFresh(now.Add(-_busPositionMaxAge-time.Second).Unix(), now) {
		t.Fatal("GPS expiry boundary changed")
	}
	src := now.Add(-2 * time.Minute)
	eta := busmodel.RawEstimated{EstimatedTime: 30, SrcUpdateTime: src.Format(time.RFC3339)}
	if arrivingExpired(eta, now) || !arrivingExpired(eta, now.Add(time.Nanosecond)) {
		t.Fatal("arrival grace boundary changed")
	}
	eta.EstimatedTime = 60
	if arrivingExpired(eta, now.Add(time.Second)) {
		t.Fatal("estimate seconds ignored")
	}
	exact := busmodel.RawEstimated{SrcUpdateTime: now.Format(time.RFC3339), DataTime: now.Add(-_busEtaFrozenGap).Format(time.RFC3339)}
	beyond := exact
	beyond.DataTime = now.Add(-_busEtaFrozenGap - time.Second).Format(time.RFC3339)
	if countFrozenEstimates([]busmodel.RawEstimated{exact, beyond}) != 1 {
		t.Fatal("frozen threshold includes equal times")
	}
}

func TestBusRawCacheTreatsEmptyValuesAndReadErrorsAsFailures(t *testing.T) {
	ctx := context.Background()
	if _, err := readBusFeedCache[busmodel.RawEstimated](ctx, &readErrorBusSink{}, "key"); !errors.Is(err, errBusFeedCacheMiss) {
		t.Fatalf("empty cache=%v", err)
	}
	sentinel := errors.New("redis unavailable")
	if _, err := readBusFeedCache[busmodel.RawEstimated](ctx, &readErrorBusSink{value: "[]", err: sentinel}, "key"); !errors.Is(err, sentinel) {
		t.Fatalf("read failure=%v", err)
	}
}

func TestBusCityFeedsRetainSourceErrorsAndIntercityEndpoints(t *testing.T) {
	ctx := context.Background()
	sentinel := errors.New("source unavailable")
	j := busLiveJob{eta: map[string]etaSource{"Taipei": stubEtaSource{err: sentinel}}}
	if err := j.loadCityETA(ctx, "Taipei", &busCityFeeds{}); !errors.Is(err, sentinel) {
		t.Fatalf("source error=%v", err)
	}
	var urls []string
	j.fetch = func(_ context.Context, url, _ string) (*shared.TDXFetch, error) {
		urls = append(urls, url)
		return &shared.TDXFetch{Modified: false}, nil
	}
	if err := j.loadCityETA(ctx, "InterCity", &busCityFeeds{}); err != nil {
		t.Fatal(err)
	}
	if err := j.loadCityPositions(ctx, "InterCity", &busCityFeeds{}); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(urls, []string{"/v2/Bus/EstimatedTimeOfArrival/InterCity", "/v2/Bus/RealTimeByFrequency/InterCity"}) {
		t.Fatalf("URLs=%v", urls)
	}
	source := &fakeLiveSource{fixtures: map[string][]byte{"eta": []byte(`[{"StopUID":"stop"}]`)}, closeErr: sentinel}
	f, err := source.Fetch(ctx, "ignored", "eta")
	if err != nil {
		t.Fatal(err)
	}
	if err := decodeCityETA("Taipei", &busCityFeeds{etaFetch: f}); !errors.Is(err, sentinel) {
		t.Fatalf("decode close error=%v", err)
	}
}

func TestFailedCityRefreshPreservesOriginalAndRefreshErrors(t *testing.T) {
	ctx := context.Background()
	original := errors.New("publish")
	refreshErr := errors.New("refresh")
	sink := &captureLiveSink{refreshErr: refreshErr, strings: map[string]string{shared.BusCityPublishedKey("Taipei"): "1"}}
	j := busLiveJob{sink: sink}
	err := original
	published := false
	j.refreshFailedCity(ctx, "Taipei", &err, &published)
	if !errors.Is(err, original) || !errors.Is(err, refreshErr) || len(sink.refresh) != 1 {
		t.Fatalf("refresh=%v %d", err, len(sink.refresh))
	}
}

func TestBusStopSnapshotPreservesPlateSpeedCrowdAndLastBus(t *testing.T) {
	now := time.Date(2026, 10, 10, 9, 0, 0, 0, time.UTC)
	b := busmodel.StationMap{StationUID: "station", GroupUID: "group", SubRouteUID: "route", StopUID: "stop", Direction: 1, StopSequence: 3, Lat: 25, Lon: 121}
	key := busPositionIdentity("route", 1)
	nearest := &models.BusPosition{PlateNumb: "near", Speed: 17, PositionLat: 25, PositionLon: 121, CrowdLevel: models.BusCrowdLevel_BUS_CROWD_CROWDED}
	speed := int16(2)
	r := &busCitySnapshot{city: "Taipei", now: now, totalStops: map[string]int{"route": 5}, stations: map[string]*models.Bus_StationArrival{}, routes: map[string]*models.Bus_RouteArrival{}, busmap: map[string][]*models.BusPosition{key: {nearest}}, atStopMap: map[busAtStopKey]stopPresence{{"route", 1, "stop"}: {plate: "at", speed: &speed}}}
	eta := busmodel.RawEstimated{EstimatedTime: 0, PlateNumb: " KKA-1288 ", IsLastBus: 1, NextBusTime: "next", SrcUpdateTime: now.Format(time.RFC3339)}
	plate := r.liveStopHistory(b, eta, 0, eta.SrcUpdateTime, key)
	if plate == nil || *plate != "KKA-1288" || len(r.historyRows) != 1 {
		t.Fatalf("plate=%v history=%v", plate, r.historyRows)
	}
	row := r.historyRows[0]
	if row[6].(*string) == nil || *row[6].(*string) != "next" || row[17].(*int16) == nil || *row[17].(*int16) != 2 || *row[18].(*int) != 0 {
		t.Fatalf("history row=%v", row)
	}
	r.atStopMap[busAtStopKey{"route", 1, "stop"}] = stopPresence{plate: "at"}
	eta.PlateNumb = ""
	if got := r.liveStopHistory(b, eta, 0, eta.SrcUpdateTime, key); got == nil || *got != "at" || *r.historyRows[1][17].(*int16) != 17 {
		t.Fatalf("near-stop fallback=%v", r.historyRows)
	}
	r.appendStationStop(b, eta, 0, 0, "", key, now.Unix(), plate, models.BusEstimateSource_BUS_ESTIMATE_SOURCE_LIVE)
	r.appendRouteStop(b, eta, 0, 0, "", key, now.Unix(), plate, models.BusEstimateSource_BUS_ESTIMATE_SOURCE_LIVE)
	if !r.stations["group"].Routes[0].IsLastBus || !r.routes["route"].Stops[0].IsLastBus {
		t.Fatal("last-bus flag lost")
	}
	eta.IsLastBus = 0
	r.appendStationStop(b, eta, 0, 0, "", key, 0, nil, models.BusEstimateSource_BUS_ESTIMATE_SOURCE_LIVE)
	r.appendRouteStop(b, eta, 0, 0, "", key, 0, nil, models.BusEstimateSource_BUS_ESTIMATE_SOURCE_LIVE)
	if r.stations["group"].Routes[1].IsLastBus || r.routes["route"].Stops[1].IsLastBus {
		t.Fatal("ordinary bus marked last")
	}
	if crowdForPlate([]*models.BusPosition{nearest}, nil) != models.BusCrowdLevel_BUS_CROWD_UNKNOWN {
		t.Fatal("nil plate has crowd")
	}
	empty := ""
	if crowdForPlate([]*models.BusPosition{nearest}, &empty) != models.BusCrowdLevel_BUS_CROWD_UNKNOWN {
		t.Fatal("empty plate has crowd")
	}
	p := "NEAR"
	if crowdForPlate([]*models.BusPosition{{PlateNumb: "other"}, nearest}, &p) != nearest.CrowdLevel {
		t.Fatal("crowd matched wrong vehicle")
	}
}

func TestBusFillKeysRequireMissingScheduledTimesAndNearestTieKeepsFirst(t *testing.T) {
	stops := []busmodel.StationMap{{SubRouteUID: "scheduled", StopUID: "s1"}, {SubRouteUID: "known", StopUID: "s2"}, {SubRouteUID: "off", StopUID: "s3"}}
	eta := map[etaKey]busmodel.RawEstimated{{"scheduled", 0, "s1"}: {StopStatus: 1}, {"known", 0, "s2"}: {StopStatus: 1, NextBusTime: "known"}, {"off", 0, "s3"}: {StopStatus: 2}}
	keys, uids := collectFillKeys(stops, eta)
	if !reflect.DeepEqual(keys, []predict.RouteDirKey{{SubRouteUID: "scheduled"}}) || len(uids) != 1 || !uids["scheduled"] {
		t.Fatalf("keys=%v uids=%v", keys, uids)
	}
	p, _, _ := nearestBus(25, 121, []*models.BusPosition{{PlateNumb: "first", PositionLat: 25, PositionLon: 121}, {PlateNumb: "second", PositionLat: 25, PositionLon: 121}})
	if p == nil || *p != "first" {
		t.Fatalf("tie selected %v", p)
	}
}

func TestBusLiveEstimateExpiresOnlyArrivingEntries(t *testing.T) {
	now := time.Now()
	eta := busmodel.RawEstimated{StopStatus: 0, SrcUpdateTime: now.Add(-time.Hour).Format(time.RFC3339)}
	status, _, _ := liveStopEstimate(eta, true, now)
	if status != _busEtaNoReading {
		t.Fatalf("expired live status=%d", status)
	}
	eta.StopStatus = 1
	status, _, _ = liveStopEstimate(eta, true, now)
	if status != 1 {
		t.Fatalf("schedule status=%d", status)
	}
}

func TestDataTaipeiZeroEstimateAndTwoBytePlainPayload(t *testing.T) {
	status, seconds, ok := dataTaipeiStopStatus("0")
	if ok || status != 0 || seconds != 0 {
		t.Fatalf("zero status=%d seconds=%d ok=%v", status, seconds, ok)
	}
	got, err := gunzipIfCompressed([]byte{0x1f, 0x00})
	if err != nil || len(got) != 2 {
		t.Fatalf("two-byte plain=%v %v", got, err)
	}
}
