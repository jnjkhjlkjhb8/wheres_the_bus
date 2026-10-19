package transit

import (
	"errors"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/nearby"
)

type failedNearSendStream struct {
	fakeNearStream
	err      error
	response *pb.RespNear
	sends    int
}

func (s *failedNearSendStream) Send(response *pb.RespNear) error {
	s.response = response
	s.sends++
	return s.err
}

func TestNearReturnsClientSendFailure(t *testing.T) {
	sendErr := errors.New("client disconnected while sending nearby results")
	stream := &failedNearSendStream{
		fakeNearStream: fakeNearStream{request: &pb.Ask_Near{
			PositionLon: 121.5, PositionLat: 25, Radius: 500,
		}},
		err: sendErr,
	}
	server := &NearServer{discovery: nearby.NewNearbyDiscovery(handlerNearbyStore{}, nil)}
	if err := server.Near(stream); !errors.Is(err, sendErr) {
		t.Fatalf("Near error = %v, want client send error %v", err, sendErr)
	}
	if stream.sends != 1 || stream.response == nil {
		t.Fatalf("nearby sends = %d, response = %v; want one discovered response", stream.sends, stream.response)
	}
}
