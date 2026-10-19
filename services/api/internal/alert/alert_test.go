package alert

import (
	"context"
	"errors"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

type alertSource struct {
	frames        [][]byte
	payload       []byte
	channel, seed string
	closed        bool
}

func (s *alertSource) Get(_ context.Context, key string) ([]byte, bool) {
	s.seed = key
	return s.payload, true
}
func (*alertSource) ScanKeys(context.Context, string) []string { return nil }
func (s *alertSource) Subscribe(_ context.Context, channel string) (<-chan []byte, func(), error) {
	s.channel = channel
	ch := make(chan []byte, len(s.frames))
	for _, frame := range s.frames {
		ch <- frame
	}
	close(ch)
	return ch, func() { s.closed = true }, nil
}
func (*alertSource) Touch(context.Context, string, time.Duration) {}

type alertStream struct {
	grpc.ServerStreamingServer[pb.Alert_Msg]
	ctx       context.Context
	messages  []*pb.Alert_Msg
	sendError error
}

func (s *alertStream) Context() context.Context { return s.ctx }
func (s *alertStream) Send(message *pb.Alert_Msg) error {
	s.messages = append(s.messages, message)
	return s.sendError
}

func TestAlertHandlersRouteAndDecodeSeeds(t *testing.T) {
	want := &pb.Alert_Msg{}
	payload, err := protojson.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	sendErr := errors.New("client disconnected")
	for _, tc := range []struct {
		name, key string
		invoke    func(*AlertServer, *alertStream) error
	}{
		{"bus", shared.AlertBusAlertChannel("Taipei"), func(server *AlertServer, stream *alertStream) error {
			return server.BusAlert(&pb.Alert_Bus_Ask{City: "Taipei"}, stream)
		}},
		{"metro", shared.AlertMetroChannel("TRTC"), func(server *AlertServer, stream *alertStream) error {
			return server.MetroAlert(&pb.Alert_Metro_Ask{System: "TRTC"}, stream)
		}},
		{"tra", shared.AlertTraChannel, func(server *AlertServer, stream *alertStream) error { return server.TraAlert(&pb.Alert_Ask{}, stream) }},
		{"thsr", shared.AlertThsrChannel, func(server *AlertServer, stream *alertStream) error { return server.ThsrAlert(&pb.Alert_Ask{}, stream) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			source := &alertSource{payload: payload}
			stream := &alertStream{ctx: t.Context(), sendError: sendErr}
			err := tc.invoke(NewAlertServer(source), stream)
			if !errors.Is(err, sendErr) || len(stream.messages) != 1 || !proto.Equal(stream.messages[0], want) {
				t.Fatalf("alert messages=%v, error=%v", stream.messages, err)
			}
			if source.channel != tc.key || source.seed != tc.key || !source.closed {
				t.Fatalf("alert routing=%+v", source)
			}
		})
	}
}

func TestMalformedAlertIsSkippedAndSubscriptionClosed(t *testing.T) {
	source := &alertSource{payload: []byte("{bad"), frames: [][]byte{[]byte("{}")}}
	want := errors.New("client disconnected")
	stream := &alertStream{ctx: t.Context(), sendError: want}
	err := NewAlertServer(source).TraAlert(&pb.Alert_Ask{}, stream)
	if !errors.Is(err, want) || len(stream.messages) != 1 || !proto.Equal(stream.messages[0], &pb.Alert_Msg{}) || !source.closed {
		t.Fatalf("alert messages=%v, error=%v, closed=%v", stream.messages, err, source.closed)
	}
}
