package maas

import (
	"context"
	"testing"

	"github.com/pashagolub/pgxmock/v4"
)

func TestConvertResolvesIdentitiesForAlternativesInTheSameBatch(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery(`(?s)WITH input AS.*bus_station_stop_map`).
		WithArgs(
			// The metro alternative never reaches the query: the batch is
			// bus-only, which is also why it can never become tappable.
			[]int32{0, 1},
			[]string{"A", "A"},
			[]string{"B", "B"},
			[]string{"307", "310"},
			[]string{"307", "310"},
			[]string{"", ""},
		).
		WillReturnRows(pgxmock.NewRows([]string{
			"section_index", "sub_route_uid", "direction", "departure_stop_uid", "arrival_stop_uid", "match_count",
		}).
			AddRow(int32(0), "BUS-307", int32(0), "STOP-A", "STOP-B", int64(1)).
			AddRow(int32(1), "BUS-310", int32(0), "STOP-A", "STOP-B", int64(1)))
	// No fare query: the only priced section here is the bus leg, and buses are
	// not part of the rail fare batch.

	leg := func(mode, name string) tdxSection {
		return tdxSection{
			Type:      "transit",
			Transport: tdxTransport{Mode: mode, Name: name, ShortName: name},
			Departure: tdxPlaceInfo{Time: "07:00", Place: tdxPlace{Name: "A"}},
			Arrival:   tdxPlaceInfo{Time: "07:20", Place: tdxPlace{Name: "B"}},
		}
	}
	main := leg("BUS", "307")
	main.Alternatives = []tdxSection{leg("BUS", "310"), leg("MRT", "藍線")}
	api := &tdxAPIResponse{}
	api.Data.Routes = []tdxRoute{{Sections: []tdxSection{main}}}

	out := convert(context.Background(), db, nil, api)
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatalf("alternatives were not folded into the existing batch: %v", err)
	}
	alternatives := out.GetRoutes()[0].GetSections()[0].GetAlternatives()
	if got := len(alternatives); got != 2 {
		t.Fatalf("alternatives = %d, want 2", got)
	}
	if got := alternatives[0].GetNotificationIdentity().GetRouteKey(); got != "BUS-310" {
		t.Errorf("bus alternative route key = %q, want BUS-310", got)
	}
	// The metro alternative has no identity to resolve, so it stays a plain
	// row in the app rather than a tap that goes nowhere.
	if alternatives[1].GetNotificationIdentity().GetSupported() {
		t.Errorf("metro alternative must not claim a route to tap through to")
	}
	// Four fields and no more: an alternative names a service and its two
	// times. Everything else belongs to the leg it would replace.
	if got := alternatives[0].GetDeparture().GetTime(); got != "07:00" {
		t.Errorf("alternative departure time = %q", got)
	}
	if alternatives[0].GetTravelSummary() != nil ||
		len(alternatives[0].GetIntermediateStops()) != 0 ||
		len(alternatives[0].GetWalkPath()) != 0 {
		t.Errorf("alternative carries payload it has no use for: %v", alternatives[0])
	}
}
