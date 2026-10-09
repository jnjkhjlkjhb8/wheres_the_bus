package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
)

// The hourly landing must stay one dataset wide: the whole point of the extra
// cadence is that it costs ~23 conditional GETs, not a second full run.
func TestIngestRawLandsOnlySelectedTables(t *testing.T) {
	t.Setenv("TDX_CLIENT_ID", "test-id")
	t.Setenv("TDX_CLIENT_SECRET", "test-secret")

	var mu sync.Mutex
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.URL.Path)
		mu.Unlock()
		w.Header().Set("Last-Modified", "fixture-v1")
		_, _ = w.Write([]byte("[]"))
	}))
	defer srv.Close()

	_ = ingestRaw(context.Background(), testTDXClient(srv.URL), "bus_dailytimetable")

	mu.Lock()
	defer mu.Unlock()
	if want := len(dataset.DailyTimetableCities()); len(seen) != want {
		t.Fatalf("fetched %d endpoints, want one per served city (%d)", len(seen), want)
	}
	for _, path := range seen {
		if city := path[strings.LastIndex(path, "/")+1:]; dataset.BusDailyTimetableSkip(city) {
			t.Errorf("fetched %s, but TDX serves no daily timetable for %s", path, city)
		}
	}
	for _, path := range seen {
		if !strings.HasPrefix(path, "/v2/Bus/DailyTimeTable/") {
			t.Errorf("fetched %s, want only /v2/Bus/DailyTimeTable/*", path)
		}
	}
}

func TestBusDailyPendingCities(t *testing.T) {
	markers := map[string]string{
		"Taoyuan":     "v2",
		"Taichung":    "v1",
		"Kaohsiung":   "v3",
		"Taipei":      "v9", // landed from Data.taipei, not TDX, but still loaded
		"NewTaipei":   "v9", // nothing lands this partition at all
		"HsinchuCity": "v1",
	}
	tests := []struct {
		name   string
		loaded map[string]string
		want   []string
	}{
		{
			name:   "fresh process loads every served city",
			loaded: map[string]string{},
			want:   []string{"HsinchuCity", "Kaohsiung", "Taichung", "Taipei", "Taoyuan"},
		},
		{
			name: "only the cities whose marker moved",
			loaded: map[string]string{
				"Taoyuan": "v1", "Taichung": "v1", "Kaohsiung": "v3",
				"HsinchuCity": "v1", "Taipei": "v9",
			},
			want: []string{"Taoyuan"},
		},
		{
			name: "quiet hour transforms nothing",
			loaded: map[string]string{
				"Taoyuan": "v2", "Taichung": "v1", "Kaohsiung": "v3",
				"HsinchuCity": "v1", "Taipei": "v9",
			},
			want: []string{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := busDailyPendingCities(markers, tt.loaded)
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("busDailyPendingCities() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestBusDailyTimetableSpecComesFromRegistry(t *testing.T) {
	spec, err := busDailyTimetableSpec(nil)
	if err != nil {
		t.Fatalf("busDailyTimetableSpec() error = %v", err)
	}
	if spec.table != "bus_dailytimetable" || spec.partCol != "city" || (spec.load == nil && spec.loadFull == nil) {
		t.Fatalf("spec = %+v, want the registry's bus_dailytimetable recipe", spec)
	}
}
