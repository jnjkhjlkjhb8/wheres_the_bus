package mrt

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/puddle/v2"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/samber/oops"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/protobuf/proto"
)

func mrtArrivalContractLogs(t *testing.T) *observer.ObservedLogs {
	t.Helper()
	core, logs := observer.New(zapcore.DebugLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	return logs
}

func mrtArrivalContractCause(entry observer.LoggedEntry) error {
	for _, field := range entry.Context {
		if field.Key == "err" {
			err, _ := field.Interface.(error)
			return err
		}
	}
	return nil
}

func mrtArrivalContractField(t *testing.T, logs *observer.ObservedLogs, event, field string, want int64) {
	t.Helper()
	found := false
	for _, entry := range logs.All() {
		values := entry.ContextMap()
		if values["event"] == event {
			if value, ok := values[field]; ok {
				if value != want {
					t.Fatalf("%s %s=%v want %d", event, field, value, want)
				}
				found = true
			}
		}
	}
	if !found {
		t.Fatalf("%s counter %s absent", event, field)
	}
}

func TestMrtArrivalNativePublishedSchedulePreservesClockBoundaries(t *testing.T) {
	for _, test := range []struct {
		name, first, last string
		now               time.Time
		want              bool
	}{
		{"minute tens and final digit", "08:39", "10:59", time.Date(2026, 1, 1, 8, 29, 0, 0, pipeline.Taipei), true},
		{"minute tens excludes earlier time", "08:39", "10:59", time.Date(2026, 1, 1, 8, 28, 0, 0, pipeline.Taipei), false},
		{"hour29 and minute59 accepted", "22:00", "29:59", time.Date(2026, 1, 1, 9, 0, 0, 0, pipeline.Taipei), false},
		{"equal first and last means next service day", "06:00", "06:00", time.Date(2026, 1, 1, 12, 0, 0, 0, pipeline.Taipei), true},
	} {
		t.Run(test.name, func(t *testing.T) {
			db := mrtNativePool(t)
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			t.Cleanup(cancel)
			if _, err := db.Exec(ctx, "INSERT INTO mrt_schedule VALUES('TRTC','BL12','BL','BL23',$1,$2)", test.first, test.last); err != nil {
				t.Fatal(err)
			}
			windows := ServiceWindows(ctx, db)
			key := WindowKey("TRTC", "BL12", "BL", "BL23")
			if len(windows[key]) != 1 {
				t.Fatal("valid schedule clock was discarded")
			}
			sink := &captureLiveSink{}
			if err := TrtcPublish(ctx, sink, _trtcTestNames, windows, test.now, []TrtcTrack{{StationName: "台北車站", DestinationName: "南港展覽館站", CountDown: "00:30"}}, nil, nil); err != nil {
				t.Fatal(err)
			}
			got := sink.setFor(shared.MrtLiveKey("TRTC", "BL12", "BL", "BL23"))
			if (got != nil) != test.want {
				t.Fatalf("published schedule arrival present=%v want %v", got != nil, test.want)
			}
			if got != nil {
				var message models.MrtLive
				if err := proto.Unmarshal(got.value, &message); err != nil {
					t.Fatal(err)
				}
				if message.EstimateTime != 30 || message.StationID != "BL12" {
					t.Fatalf("arrival=%v", &message)
				}
			}
		})
	}
}

func TestMrtArrivalNativePublicationIncludesExactGraceEndpoints(t *testing.T) {
	windows := map[string][]ServiceWindow{WindowKey("TRTC", "BL12", "BL", "BL23"): {{first: 360, last: 720}}}
	for _, test := range []struct {
		name         string
		hour, minute int
		want         bool
	}{
		{"first minus ten minutes", 5, 50, true}, {"just before first grace", 5, 49, false},
		{"last plus ten minutes", 12, 10, true}, {"just after last grace", 12, 11, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			sink := &captureLiveSink{}
			now := time.Date(2026, 1, 1, test.hour, test.minute, 0, 0, pipeline.Taipei)
			if err := TrtcPublish(t.Context(), sink, _trtcTestNames, windows, now, []TrtcTrack{{StationName: "台北車站", DestinationName: "南港展覽館站", CountDown: "00:30"}}, nil, nil); err != nil {
				t.Fatal(err)
			}
			if got := sink.setFor(shared.MrtLiveKey("TRTC", "BL12", "BL", "BL23")); (got != nil) != test.want {
				t.Fatalf("arrival at grace endpoint present=%v want %v", got != nil, test.want)
			}
		})
	}
}

func TestMrtArrivalNativeDecodeFailureRetainsSystemAndFetchOwnership(t *testing.T) {
	sink := &captureLiveSink{}
	closed, acked := false, false
	closeFetch := func() error { closed = true; return nil }
	t.Cleanup(func() {
		if !closed {
			_ = closeFetch()
		}
	})
	fetch := func(_ context.Context, _, name string) (*shared.TDXFetch, error) {
		if name != "mrt_LiveBoardTRTC" {
			return &shared.TDXFetch{Modified: false}, nil
		}
		return &shared.TDXFetch{Modified: true, Decoder: json.NewDecoder(strings.NewReader(`[bad]`)), Close: closeFetch, Ack: func() error { acked = true; return nil }}, nil
	}
	err := Eta(t.Context(), fetch, sink, nil)
	var syntaxErr *json.SyntaxError
	if !errors.As(err, &syntaxErr) {
		t.Fatalf("invalid board lost decode cause: %v", err)
	}
	detailed, ok := oops.AsOops(err)
	if !ok || detailed.Context()["system"] != "TRTC" {
		t.Fatalf("board failure lost system identity: %v", err)
	}
	if !closed || acked || len(sink.contexts) != 0 {
		t.Fatalf("failed board lifecycle closed=%v acked=%v executed=%d", closed, acked, len(sink.contexts))
	}
}

func TestMrtArrivalNativeFilteredBoardReportsCountAndNoSpuriousZero(t *testing.T) {
	for _, filtered := range []bool{false, true} {
		name := "in service"
		if filtered {
			name = "outside service"
		}
		t.Run(name, func(t *testing.T) {
			logs := mrtArrivalContractLogs(t)
			db := mrtNativePool(t)
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			t.Cleanup(cancel)
			now := time.Now().In(pipeline.Taipei)
			first, last := "00:00", "29:59"
			if filtered {
				first = now.Add(2 * time.Hour).Format("15:04")
				last = now.Add(3 * time.Hour).Format("15:04")
			}
			if _, err := db.Exec(ctx, "INSERT INTO mrt_schedule VALUES('TRTC','BL12','BL','BL23',$1,$2)", first, last); err != nil {
				t.Fatal(err)
			}
			sink := &captureLiveSink{}
			closed, acked := false, false
			closeFetch := func() error { closed = true; return nil }
			t.Cleanup(func() {
				if !closed {
					_ = closeFetch()
				}
			})
			fetch := func(_ context.Context, _, key string) (*shared.TDXFetch, error) {
				if key != "mrt_LiveBoardTRTC" {
					return &shared.TDXFetch{Modified: false}, nil
				}
				body := `[{"StationID":"BL12","LineID":"BL","DestinationStaionID":"BL23","EstimateTime":30},{"StationID":"BL12","LineID":"BL","DestinationStaionID":"BL23","EstimateTime":60}]`
				return &shared.TDXFetch{Modified: true, Decoder: json.NewDecoder(strings.NewReader(body)), Close: closeFetch, Ack: func() error { acked = true; return nil }}, nil
			}
			if err := Eta(ctx, fetch, sink, db); err != nil {
				t.Fatal(err)
			}
			if !closed || !acked {
				t.Fatal("complete filtered snapshot did not close and acknowledge")
			}
			if filtered {
				if len(sink.sets) != 0 || len(sink.owned[shared.LiveOwnedKeysKey("mrt", "TRTC")]) != 0 {
					t.Fatal("out-of-service rows were published")
				}
				mrtArrivalContractField(t, logs, "out_of_service_filtered", "count", 2)
			} else {
				if len(sink.sets) != 2 {
					t.Fatalf("in-service rows=%d", len(sink.sets))
				}
				for _, entry := range logs.All() {
					if entry.ContextMap()["event"] == "out_of_service_filtered" {
						t.Fatal("unfiltered board emitted a false filtered-rows report")
					}
				}
			}
		})
	}
}

func TestMrtArrivalNativeTRTCCompletionDistinguishesDroppedAndFiltered(t *testing.T) {
	logs := mrtArrivalContractLogs(t)
	sink := &captureLiveSink{}
	windows := map[string][]ServiceWindow{WindowKey("TRTC", "BL12", "BL", "BL23"): {{first: 360, last: 420}}}
	tracks := []TrtcTrack{
		{StationName: "unknown", DestinationName: "南港展覽館站", CountDown: "00:30"},
		{StationName: "台北車站", DestinationName: "南港展覽館站", CountDown: "00:30"},
		{StationName: "台北車站", DestinationName: "頂埔站", CountDown: "00:30"},
	}
	if err := TrtcPublish(t.Context(), sink, _trtcTestNames, windows, time.Date(2026, 1, 1, 12, 0, 0, 0, pipeline.Taipei), tracks, nil, nil); err != nil {
		t.Fatal(err)
	}
	if len(sink.sets) != 1 || sink.setFor(shared.MrtLiveKey("TRTC", "BL12", "BL", "BL01")) == nil {
		t.Fatal("valid arrival did not survive unrelated dropped/filtered rows")
	}
	mrtArrivalContractField(t, logs, "complete", "arrivals", 1)
	mrtArrivalContractField(t, logs, "complete", "dropped", 1)
	mrtArrivalContractField(t, logs, "complete", "out_of_service", 1)
}

func mrtArrivalContractSOAP(t *testing.T) {
	t.Helper()
	t.Setenv("TRTC_USERNAME", "owned-user")
	t.Setenv("TRTC_PASSWORD", "owned-password")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/TrackInfo.asmx" {
			_, _ = io.WriteString(w, `[{"StationName":"起站","DestinationName":"終站","CountDown":"00:30"}]`)
			return
		}
		_, _ = io.WriteString(w, `[]`)
	}))
	t.Cleanup(server.Close)
	previous := _trtcClient
	client := resty.New().SetBaseURL(server.URL).SetTimeout(5 * time.Second)
	t.Cleanup(func() { _trtcClient = previous; client.GetClient().CloseIdleConnections() })
	_trtcClient = client
}

func TestMrtArrivalNativeTRTCBareJSONArrayStillPublishes(t *testing.T) {
	mrtArrivalContractSOAP(t)
	db := mrtNativePool(t)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	t.Cleanup(cancel)
	if _, err := db.Exec(ctx, "INSERT INTO mrt_station VALUES('TRTC','BL12','起站'),('TRTC','BL23','終站')"); err != nil {
		t.Fatal(err)
	}
	sink := &captureLiveSink{}
	if err := TrtcEta(ctx, sink, db); err != nil {
		t.Fatal(err)
	}
	write := sink.setFor(shared.MrtLiveKey("TRTC", "BL12", "BL", "BL23"))
	if write == nil {
		t.Fatal("bare JSON array discarded valid TRTC arrival")
	}
	var arrival models.MrtLive
	if err := proto.Unmarshal(write.value, &arrival); err != nil {
		t.Fatal(err)
	}
	if arrival.EstimateTime != 30 || arrival.StationID != "BL12" || arrival.DestinationStaionID != "BL23" {
		t.Fatalf("published bare-array arrival=%v", &arrival)
	}
}

func TestMrtArrivalNativeTRTCStationLookupRetainsClosedPoolCause(t *testing.T) {
	mrtArrivalContractSOAP(t)
	db, err := pgxpool.New(t.Context(), "postgres://owned:owned@127.0.0.1:1/owned?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	t.Cleanup(cancel)
	sink := &captureLiveSink{}
	if err := TrtcEta(ctx, sink, db); !errors.Is(err, puddle.ErrClosedPool) {
		t.Fatalf("station mapping lost database cause: %v", err)
	}
	if len(sink.sets) != 0 || len(sink.contexts) != 0 {
		t.Fatal("failed station mapping published arrivals")
	}
}

func TestMrtArrivalNativeExpiredWindowsRetainLastGoodAndQueryCause(t *testing.T) {
	logs := mrtArrivalContractLogs(t)
	db := mrtNativePool(t)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	t.Cleanup(cancel)
	if _, err := db.Exec(ctx, "INSERT INTO mrt_schedule VALUES('TRTC','BL12','BL','BL23','06:00','12:00')"); err != nil {
		t.Fatal(err)
	}
	key := WindowKey("TRTC", "BL12", "BL", "BL23")
	original := ServiceWindows(ctx, db)
	_mrtWindowCache.Lock()
	_mrtWindowCache.loaded = time.Now().Add(-2 * time.Hour)
	_mrtWindowCache.Unlock()
	db.Close()
	windows := ServiceWindows(ctx, db)
	if len(windows[key]) != 1 || windows[key][0] != original[key][0] {
		t.Fatal("expired refresh failure discarded last-good window")
	}
	found := false
	for _, entry := range logs.All() {
		if entry.ContextMap()["event"] == "query_error" {
			if !errors.Is(mrtArrivalContractCause(entry), puddle.ErrClosedPool) {
				t.Fatalf("window refresh lost original query cause: %v", mrtArrivalContractCause(entry))
			}
			found = true
		}
	}
	if !found {
		t.Fatal("failed expired window refresh was silent")
	}
}
