package transit

import (
	"context"
	"errors"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestNearReceiverCancellationRacingQueuedPositionsJoinsTheReceiver(t *testing.T) {
	for range 32 {
		ctx, cancel := context.WithCancel(t.Context())
		cancel()
		requests := make(chan *pb.Ask_Near)
		var recvErr error
		finished := make(chan struct{})
		go func() {
			requests <- &pb.Ask_Near{PositionLat: 25}
			recvErr = context.Canceled
			close(requests)
			close(finished)
		}()
		for {
			in, err := receiveNearRequest(ctx, requests, &recvErr)
			if in != nil {
				continue
			}
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("cancelled receiver error = %v", err)
			}
			break
		}
		<-finished
	}
}

func TestNearReceiverDrainJoinsAndDiscardsQueuedPositions(t *testing.T) {
	requests := make(chan *pb.Ask_Near)
	finished := make(chan struct{})
	go func() {
		requests <- &pb.Ask_Near{PositionLat: 25}
		close(requests)
		close(finished)
	}()
	drainNearRequests(requests)
	<-finished
}

func TestStationEtaDoesNotInventCityAfterLookupFailure(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery(`SELECT city FROM bus_station_groups`).WithArgs("group").WillReturnError(errors.New("city unavailable"))
	if got := resolveStationEtaCity(t.Context(), db, &pb.Bus_Ask_StationGroup{GroupUid: "group"}); got != "" {
		t.Fatalf("failed city lookup = %q", got)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
