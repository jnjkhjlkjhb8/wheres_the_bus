package bike

import (
	"context"
	"strings"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
)

func TestLoadBikeStationsRejectsMalformedElement(t *testing.T) {
	sink := &fakeLoadSink{}
	err := LoadStations(context.Background(), decodeInto(`[
		{"StationUID":"TPE001","StationID":"001","StationPosition":{"PositionLon":121.5,"PositionLat":25.0},"ServiceType":2},
		{"StationUID":
	]`), sink, "Taipei")
	if err == nil || !errMentions(err, "element 1") {
		t.Fatalf("LoadStations error = %v, want wrapped element 1 decode error", err)
	}
	if len(sink.calls) != 0 {
		t.Fatalf("copyUpsert calls = %d, want no write for malformed payload", len(sink.calls))
	}
}

func TestLoadBikeStationsRejectsInvalidIdentityOrPosition(t *testing.T) {
	tests := []struct {
		name string
		body string
		want string
	}{
		{
			name: "missing station uid",
			body: `[{"StationID":"001","StationPosition":{"PositionLon":121.5,"PositionLat":25.0},"ServiceType":2}]`,
			want: "StationUID",
		},
		{
			name: "zero position",
			body: `[{"StationUID":"TPE001","StationID":"001","StationPosition":{"PositionLon":0,"PositionLat":0},"ServiceType":2}]`,
			want: "position",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sink := &fakeLoadSink{}
			err := LoadStations(context.Background(), decodeInto(tt.body), sink, "Taipei")
			if err == nil || !errMentions(err, tt.want) {
				t.Fatalf("LoadStations error = %v, want %q validation error", err, tt.want)
			}
			if len(sink.calls) != 0 {
				t.Fatalf("copyUpsert calls = %d, want no write for invalid station", len(sink.calls))
			}
		})
	}
}

func TestLoadBikeStationsAcceptsUnknownServiceType(t *testing.T) {
	sink := &fakeLoadSink{}
	err := LoadStations(context.Background(), decodeInto(
		`[{"StationUID":"CHA001","StationID":"001","StationPosition":{"PositionLon":120.5,"PositionLat":24.0},"ServiceType":3}]`,
	), sink, "ChanghuaCounty")
	if err != nil {
		t.Fatalf("LoadStations error = %v, want an unknown ServiceType to load", err)
	}
	if len(sink.calls) == 0 {
		t.Fatal("copyUpsert calls = 0, want the station written through")
	}
}

func TestBikeCountsDecodeAbove255(t *testing.T) {
	var avail bikeAvailability
	if err := pipeline.DecodeLiveItems(decodeInto(
		`[{"StationUID":"CHA001","ServiceStatus":1,"ServiceType":2,"AvailableReturnBikes":300,`+
			`"AvailableRentBikesDetail":{"GeneralBikes":321,"ElectricBikes":260}}]`,
	), func(item bikeAvailability) error {
		avail = item
		return nil
	}); err != nil {
		t.Fatalf("decode bike availability: %v", err)
	}
	if avail.AvailableReturnBikes != 300 ||
		avail.AvailableRentBikesDetail.GeneralBikes != 321 ||
		avail.AvailableRentBikesDetail.ElectricBikes != 260 {
		t.Fatalf("decoded counts = %+v, want 300/321/260", avail)
	}

	sink := &fakeLoadSink{}
	if err := LoadStations(context.Background(), decodeInto(
		`[{"StationUID":"CHA001","StationID":"001","StationPosition":{"PositionLon":120.5,"PositionLat":24.0},`+
			`"BikesCapacity":400,"ServiceType":2}]`,
	), sink, "ChanghuaCounty"); err != nil {
		t.Fatalf("LoadStations error = %v, want a 400-dock station to load", err)
	}
	if len(sink.calls) == 0 {
		t.Fatal("copyUpsert calls = 0, want the high-capacity station written through")
	}
}

func TestLoadBikeStationsDuplicatePolicy(t *testing.T) {
	station := `{"StationUID":"TPE001","StationID":"001","StationPosition":{"PositionLon":121.5,"PositionLat":25.0},"ServiceType":2}`
	t.Run("identical dedupe", func(t *testing.T) {
		sink := &fakeLoadSink{}
		if err := LoadStations(context.Background(), decodeInto(`[`+station+`,`+station+`]`), sink, "Taipei"); err != nil {
			t.Fatalf("LoadStations: %v", err)
		}
		if len(sink.calls) != 1 || len(sink.calls[0].rows) != 1 {
			t.Fatalf("rows = %+v, want one deduped station", sink.calls)
		}
	})
	t.Run("divergent reject", func(t *testing.T) {
		sink := &fakeLoadSink{}
		other := `{"StationUID":"TPE001","StationID":"001","StationPosition":{"PositionLon":121.6,"PositionLat":25.0},"ServiceType":2}`
		err := LoadStations(context.Background(), decodeInto(`[`+station+`,`+other+`]`), sink, "Taipei")
		if err == nil || !errMentions(err, "duplicate StationUID") {
			t.Fatalf("LoadStations error = %v, want divergent duplicate error", err)
		}
		if len(sink.calls) != 0 {
			t.Fatal("divergent duplicate reached sink")
		}
	})
}

func TestLoadBikeStationsConflictRefreshesStationID(t *testing.T) {
	sink := &fakeLoadSink{}
	body := `[{"StationUID":"TPE001","StationID":"NEW-ID","StationPosition":{"PositionLon":121.5,"PositionLat":25.0},"ServiceType":2}]`
	if err := LoadStations(context.Background(), decodeInto(body), sink, "Taipei"); err != nil {
		t.Fatalf("LoadStations: %v", err)
	}
	if len(sink.calls) != 1 || !strings.Contains(sink.calls[0].spec.InsertSQL, "station_id = EXCLUDED.station_id") {
		t.Fatalf("bike conflict SQL does not refresh station_id:\n%s", sink.calls[0].spec.InsertSQL)
	}
}
