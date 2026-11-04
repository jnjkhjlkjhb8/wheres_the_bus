package maas

// MOTIS response conversion: section fares and the cache key. Split out of maas_test.go for size; both files are the
// same package and share its fakes.

import (
	"context"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/pashagolub/pgxmock/v4"
)

// clampInt guards the plan-request parameters; a broken zero-default breaks
// every old client that omits the field.
func TestClampInt(t *testing.T) {
	tests := []struct {
		name                   string
		v, min, max, def, want int32
	}{
		{"unset falls back to default when 0 invalid", 0, 1, 10, 5, 5},
		{"zero kept when 0 within range", 0, 0, 10, 5, 0},
		{"zero kept when range spans negative", 0, -5, 5, 3, 0},
		{"below min clamps up", -3, 1, 10, 5, 1},
		{"above max clamps down", 99, 1, 10, 5, 10},
		{"in range passes through", 7, 1, 10, 5, 7},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := clampInt(tt.v, tt.min, tt.max, tt.def); got != tt.want {
				t.Fatalf("clampInt(%d,%d,%d,%d) = %d, want %d", tt.v, tt.min, tt.max, tt.def, got, tt.want)
			}
		})
	}
}

// A cache-key collision between different plan requests would serve one user
// another user's journey plan; identical requests must hit the same key or the
// cache never helps.
func TestMaasKeyIdentityAndCollision(t *testing.T) {
	base := func() *pb.MaasPlanRequest {
		return &pb.MaasPlanRequest{
			FromLat: 25.0478, FromLon: 121.5170, ToLat: 25.0330, ToLon: 121.5654,
			Date: "2026-07-11", Time: "08:00", Top: 5,
		}
	}
	first, second := maasKey(base()), maasKey(base())
	if first != second {
		t.Fatal("identical requests must produce the same cache key")
	}
	mutations := map[string]func(r *pb.MaasPlanRequest){
		"destination": func(r *pb.MaasPlanRequest) { r.ToLat += 0.001 },
		"date":        func(r *pb.MaasPlanRequest) { r.Date = "2026-07-12" },
		"arrive_by":   func(r *pb.MaasPlanRequest) { r.ArriveBy = true },
		"modes":       func(r *pb.MaasPlanRequest) { r.TransitModes = []int32{3} },
	}
	seen := map[string]string{maasKey(base()): "base"}
	for name, mutate := range mutations {
		r := base()
		mutate(r)
		key := maasKey(r)
		if prev, dup := seen[key]; dup {
			t.Fatalf("cache key collision between %q and %q", name, prev)
		}
		seen[key] = name
	}
}

func TestBatchSectionFaresPicksFullTraFare(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	db.ExpectQuery("f.ticket_type = '成復'").
		WithArgs([]int32{0}, []string{"rail"}, []string{"臺北"}, []string{"臺中"}).
		WillReturnRows(pgxmock.NewRows([]string{"section_index", "fare"}).
			AddRow(int32(0), int32(375)))

	section := &pb.Section{}
	route := &pb.Route{}
	src := tdxSection{}
	src.Transport.Mode = "RAIL"
	src.Departure.Place.Name = "臺北"
	src.Arrival.Place.Name = "臺中"

	batchSectionFares(context.Background(), db, []maasSectionRef{
		{index: 0, source: src, target: section, route: route},
	})

	if section.Fare != 375 || route.TotalFare != 375 {
		t.Fatalf("fare = %d, total = %d, want 375 both", section.Fare, route.TotalFare)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
