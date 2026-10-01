package feed

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/protobuf/proto"
)

func mustMarshalBikeEta(t *testing.T, eta *models.BikeEta) string {
	t.Helper()
	raw, err := proto.Marshal(eta)
	if err != nil {
		t.Fatalf("marshal bike eta: %v", err)
	}
	return string(raw)
}

func TestDecodeBikeStatus(t *testing.T) {
	const now = int64(1700000000)

	t.Run("in service sums both bike kinds", func(t *testing.T) {
		value := mustMarshalBikeEta(t, &models.BikeEta{
			StationUID:           "TPE500101001",
			ServiceStatus:        1,
			GeneralBikes:         7,
			ElectricBikes:        3,
			AvailableReturnBikes: 12,
		})
		got, ok := decodeBikeStatus("TPE500101001", value, now)
		if !ok {
			t.Fatal("in-service station was refused")
		}
		if got.NumBikesAvailable != 10 {
			t.Errorf("NumBikesAvailable = %d, want 10 (7 general + 3 electric)", got.NumBikesAvailable)
		}
		if got.NumDocksAvailable != 12 {
			t.Errorf("NumDocksAvailable = %d, want 12", got.NumDocksAvailable)
		}
		if !got.IsInstalled || !got.IsRenting || !got.IsReturning {
			t.Errorf("installed/renting/returning = %v/%v/%v, want all true",
				got.IsInstalled, got.IsRenting, got.IsReturning)
		}
		if got.LastReported != now {
			t.Errorf("LastReported = %d, want %d", got.LastReported, now)
		}
	})

	// A suspended station is still physically installed, so a planner may route
	// past it, but it can neither lend nor accept a bike.
	t.Run("suspended is installed but not usable", func(t *testing.T) {
		value := mustMarshalBikeEta(t, &models.BikeEta{StationUID: "s", ServiceStatus: 2, GeneralBikes: 4})
		got, ok := decodeBikeStatus("s", value, now)
		if !ok {
			t.Fatal("suspended station was refused")
		}
		if !got.IsInstalled {
			t.Error("IsInstalled = false, want true: a suspended dock is still there")
		}
		if got.IsRenting || got.IsReturning {
			t.Errorf("renting/returning = %v/%v, want both false", got.IsRenting, got.IsReturning)
		}
	})

	// StationUID is set because every cached message carries it: proto3 drops
	// zero fields, so a Bike_eta with nothing but ServiceStatus 0 marshals to
	// zero bytes and is indistinguishable from a missing key.
	t.Run("stopped is not installed", func(t *testing.T) {
		value := mustMarshalBikeEta(t, &models.BikeEta{StationUID: "s", ServiceStatus: 0})
		got, ok := decodeBikeStatus("s", value, now)
		if !ok {
			t.Fatal("stopped station was refused")
		}
		if got.IsInstalled {
			t.Error("IsInstalled = true, want false")
		}
	})

	// These are the cases the handler drops. Reporting them as zeroed stations
	// would assert an empty dock, which is a different claim from "unknown".
	t.Run("refuses what it cannot decode", func(t *testing.T) {
		for name, value := range map[string]any{
			"missing key": nil,
			"empty value": "",
			"wrong type":  42,
			"not proto":   "\xff\xff\xff\xff",
		} {
			if _, ok := decodeBikeStatus("s", value, now); ok {
				t.Errorf("%s: accepted, want refused", name)
			}
		}
	})
}

// TestGBFSDiscoveryAdvertisesServedFiles asserts the auto-discovery document
// points only at files that exist: a consumer follows these URLs blindly, so an
// advertised-but-unrouted file is a 404 in someone else's planner.
func TestGBFSDiscoveryAdvertisesServedFiles(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	// Nil db/redis are safe here: only the discovery route is exercised, and its
	// handler touches neither.
	RegisterGBFSRoutes(r, nil, nil, func(*gin.Context) {}, "8080")

	recorder := httptest.NewRecorder()
	r.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/gbfs/gbfs.json", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("gbfs.json status = %d, want 200", recorder.Code)
	}

	var body struct {
		Version string `json:"version"`
		TTL     int    `json:"ttl"`
		Data    map[string]struct {
			Feeds []struct {
				Name string `json:"name"`
				URL  string `json:"url"`
			} `json:"feeds"`
		} `json:"data"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode gbfs.json: %v", err)
	}
	if body.Version != _gbfsVersion {
		t.Errorf("version = %q, want %q", body.Version, _gbfsVersion)
	}
	if body.TTL <= 0 {
		t.Errorf("ttl = %d, want positive: a consumer uses it to schedule re-polls", body.TTL)
	}
	language, ok := body.Data["zh-TW"]
	if !ok {
		t.Fatalf("no zh-TW feed set in %v", body.Data)
	}
	if len(language.Feeds) != len(_gbfsFeedNames) {
		t.Fatalf("advertised %d feeds, want %d", len(language.Feeds), len(_gbfsFeedNames))
	}

	routed := map[string]bool{}
	for _, route := range r.Routes() {
		routed[route.Path] = true
	}
	for _, feed := range language.Feeds {
		want := "/gbfs/" + feed.Name + ".json"
		if !routed[want] {
			t.Errorf("gbfs.json advertises %q but %s is not routed", feed.URL, want)
		}
	}
}
