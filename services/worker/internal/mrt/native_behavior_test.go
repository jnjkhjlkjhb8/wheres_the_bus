package mrt

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/protobuf/proto"
)

func mrtNativePool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL required")
	}
	admin, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("quality_mrt_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(context.Background(), "CREATE SCHEMA "+quoted+"; CREATE TABLE "+quoted+".mrt_schedule(system text,station_id text,lineid text,destinationstaionid text,firsttraintime text,lasttraintime text);CREATE TABLE "+quoted+".mrt_station(system text,station_id text,name text)"); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+quoted+" CASCADE"); admin.Close() })
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema
	db, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	_mrtWindowCache.Lock()
	saved, loaded := _mrtWindowCache.byKey, _mrtWindowCache.loaded
	_mrtWindowCache.byKey = nil
	_mrtWindowCache.loaded = time.Time{}
	_mrtWindowCache.Unlock()
	t.Cleanup(func() {
		_mrtWindowCache.Lock()
		_mrtWindowCache.byKey = saved
		_mrtWindowCache.loaded = loaded
		_mrtWindowCache.Unlock()
	})
	return db
}

func TestServiceWindowNativeRowsOvernightAndStaleFallback(t *testing.T) {
	db := mrtNativePool(t)
	ctx := context.Background()
	if ServiceWindows(ctx, nil) != nil {
		t.Fatal("nil database has windows")
	}
	if _, err := db.Exec(ctx, `INSERT INTO mrt_schedule VALUES
 ('TRTC','BL05','BL','BL20','06:00','00:40'),
 ('TRTC','BL05','BL','BL20','07:00','25:00'),
 ('TRTC','BL05','BL','BL20','bad','09:00'),
 ('TRTC','BL05','BL','BL20','06:00','bad')`); err != nil {
		t.Fatal(err)
	}
	key := WindowKey("TRTC", "BL05", "BL", "BL20")
	windows := ServiceWindows(ctx, db)
	if len(windows[key]) != 2 || windows[key][0].first != 360 || windows[key][0].last != 1480 || windows[key][1].last != 1500 {
		t.Fatalf("windows=%v", windows)
	}
	if _, err := db.Exec(ctx, "DELETE FROM mrt_schedule"); err != nil {
		t.Fatal(err)
	}
	if len(ServiceWindows(ctx, db)[key]) != 2 {
		t.Fatal("cache reloaded before TTL")
	}
	_mrtWindowCache.loaded = time.Now().Add(-2 * _mrtWindowCacheTTL)
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if len(ServiceWindows(cancelled, db)[key]) != 2 {
		t.Fatal("query failure discarded stale cache")
	}
	if _, err := db.Exec(ctx, "INSERT INTO mrt_schedule VALUES('TRTC','BL05','BL','BL20',NULL,'09:00')"); err != nil {
		t.Fatal(err)
	}
	if len(ServiceWindows(ctx, db)[key]) != 2 {
		t.Fatal("scan failure discarded stale cache")
	}
}

func TestTrtcNativeSOAPAndStationMappingWithOptionalWeights(t *testing.T) {
	db := mrtNativePool(t)
	ctx := context.Background()
	if _, err := db.Exec(ctx, `INSERT INTO mrt_station VALUES ('TRTC','BL05','起站'),('TRTC','BL20','終站'),('KRTC','R1','ignored')`); err != nil {
		t.Fatal(err)
	}
	old := _trtcClient
	t.Cleanup(func() { _trtcClient = old })
	t.Setenv("TRTC_USERNAME", "user&")
	t.Setenv("TRTC_PASSWORD", "pass<")
	for _, tc := range []struct {
		name, trackBody string
		trackStatus     int
		wantErr         bool
	}{{"valid", `[{"StationName":"起站","DestinationName":"終站","CountDown":"00:30"}]`, 200, false}, {"bad status", `[]`, 502, true}, {"no array", `not-array`, 200, true}, {"bad JSON", `[bad]`, 200, true}} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				if r.Method != http.MethodPost || !strings.Contains(string(body), "user&amp;") || !strings.Contains(string(body), "pass&lt;") {
					t.Errorf("SOAP credentials/method=%s %s", r.Method, body)
				}
				if r.URL.Path == "/TrackInfo.asmx" {
					w.WriteHeader(tc.trackStatus)
					_, _ = io.WriteString(w, "<soap>"+tc.trackBody+"</soap>")
					return
				}
				w.WriteHeader(http.StatusBadGateway)
			}))
			defer server.Close()
			_trtcClient = resty.New().SetBaseURL(server.URL).SetHeader("Content-Type", "application/soap+xml; charset=utf-8")
			sink := &captureLiveSink{}
			err := TrtcEta(ctx, sink, db)
			if (err != nil) != tc.wantErr {
				t.Fatalf("ETA=%v", err)
			}
			if !tc.wantErr {
				write := sink.setFor(shared.MrtLiveKey("TRTC", "BL05", "BL", "BL20"))
				if write == nil {
					t.Fatal("arrival not published")
				}
				var live models.MrtLive
				if err := proto.Unmarshal(write.value, &live); err != nil {
					t.Fatal(err)
				}
				if live.EstimateTime != 30 || live.Weight != nil {
					t.Fatalf("countdown-only arrival=%v", &live)
				}
			}
		})
	}
	t.Setenv("TRTC_USERNAME", "")
	if err := TrtcEta(ctx, nil, nil); err != nil {
		t.Fatal(err)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := trtcStationNames(canceled, db); err == nil {
		t.Fatal("canceled station query succeeded")
	}
}

func TestMrtEtaPublishesEachSystemAndRetainsFailures(t *testing.T) {
	for _, tc := range []struct {
		name, raw         string
		fresh             bool
		fetchErr, execErr error
	}{{"modified", `[{"StationID":"s","LineID":"l","DestinationStaionID":"d","EstimateTime":12}]`, true, nil, nil}, {"unmodified", "", false, nil, nil}, {"malformed", "[bad]", true, nil, nil}, {"fetch failure", "", false, errors.New("fetch"), nil}, {"publish failure", "[]", true, nil, errors.New("write")}} {
		t.Run(tc.name, func(t *testing.T) {
			sink := &captureLiveSink{execErr: tc.execErr}
			acks := 0
			calls := 0
			fetch := func(_ context.Context, url, _ string) (*shared.TDXFetch, error) {
				calls++
				if !strings.Contains(url, "/LiveBoard/") {
					t.Errorf("URL=%s", url)
				}
				if tc.fetchErr != nil {
					return nil, tc.fetchErr
				}
				return &shared.TDXFetch{Modified: tc.fresh, Decoder: json.NewDecoder(strings.NewReader(tc.raw)), Close: func() error { return nil }, Ack: func() error { acks++; return nil }}, nil
			}
			err := Eta(context.Background(), fetch, sink, nil)
			failed := tc.fetchErr != nil || tc.execErr != nil || tc.name == "malformed"
			if (err != nil) != failed || calls != 4 {
				t.Fatalf("err=%v calls=%d", err, calls)
			}
			if tc.name == "modified" && (acks != 4 || len(sink.sets) != 4) {
				t.Fatalf("acks=%d sets=%v", acks, sink.sets)
			}
			if failed && acks != 0 {
				t.Fatal("failed response acknowledged")
			}
		})
	}
}
