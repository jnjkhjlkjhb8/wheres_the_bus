package mrtsync

import (
	"context"
	"errors"
	"math"
	"testing"

	"github.com/jackc/pgx/v5"
	"google.golang.org/protobuf/proto"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

func TestBusRouteRowRejectsBadPayloads(t *testing.T) {
	if _, err := busRouteRow([]byte{0xff, 0xff}); err == nil {
		t.Error("decoding a corrupt pb succeeded")
	}
	for _, dir := range []int32{0, 1} {
		pb, err := proto.Marshal(&models.BusSubroute{SubRouteUID: "X", Directions: map[int32]*models.Direction{
			dir: {Stops: []*models.BusStop{{StopUID: "S", PositionLat: math.NaN()}}},
		}})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := busRouteRow(pb); err == nil {
			t.Errorf("direction %d: a NaN position encoded; it must fail the sync", dir)
		}
	}
}

func TestBusRouteRowWithoutDirectionsHasEmptyStops(t *testing.T) {
	pb, err := proto.Marshal(&models.BusSubroute{SubRouteUID: "X", City: "Taipei"})
	if err != nil {
		t.Fatal(err)
	}
	row, err := busRouteRow(pb)
	if err != nil {
		t.Fatal(err)
	}
	if len(row) != len(_busRouteOffline.columns()) || row[8] != "[]" || row[9] != "[]" {
		t.Fatalf("row = %v", row)
	}
}

type _failingSource struct{}

func (_failingSource) Query(context.Context, string, ...any) (pgx.Rows, error) {
	return nil, errors.New("connection reset")
}

func TestReadBusRoutesReportsSourceFailure(t *testing.T) {
	if _, err := readBusRoutes(context.Background(), _failingSource{}); err == nil {
		t.Fatal("reading from a failed source succeeded")
	}
}
