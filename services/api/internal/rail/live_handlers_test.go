package rail

import (
	"context"
	"errors"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type railLiveSource struct {
	payload          []byte
	channel, pattern string
	keys             []string
	closed           bool
	demand           []string
}

func (s *railLiveSource) Get(_ context.Context, key string) ([]byte, bool) {
	s.keys = append(s.keys, key)
	return s.payload, true
}
func (s *railLiveSource) ScanKeys(_ context.Context, pattern string) []string {
	s.pattern = pattern
	return []string{"seat-key"}
}
func (s *railLiveSource) Subscribe(_ context.Context, channel string) (<-chan []byte, func(), error) {
	s.channel = channel
	ch := make(chan []byte)
	close(ch)
	return ch, func() { s.closed = true }, nil
}
func (s *railLiveSource) Touch(_ context.Context, key string, _ time.Duration) {
	s.demand = append(s.demand, key)
}

type railRecordingStream[T any] struct {
	grpc.ServerStreamingServer[T]
	ctx       context.Context
	messages  []*T
	sendError error
}

func (s *railRecordingStream[T]) Context() context.Context { return s.ctx }
func (s *railRecordingStream[T]) Send(message *T) error {
	s.messages = append(s.messages, message)
	return s.sendError
}

func TestTRAStreamHandlersDecodeSeedAndPropagateSendFailure(t *testing.T) {
	want := &pb.TraDelays{Delay: map[string]int32{"123": 5}}
	encoded, err := proto.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, channel string
		invoke        func(*railLiveSource, *railRecordingStream[pb.RespTraDelay]) error
	}{
		{"board", shared.TraDelayAllKey, func(source *railLiveSource, stream *railRecordingStream[pb.RespTraDelay]) error {
			return (&TraTimetableServer{live: source}).Delay(&pb.AskRoute{}, stream)
		}},
		{"train", shared.TraDelayTrainChannel("123"), func(source *railLiveSource, stream *railRecordingStream[pb.RespTraDelay]) error {
			return (&TraDetainServer{live: source}).Delay(&pb.AskDetain{Trainno: "123"}, stream)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			source := &railLiveSource{payload: encoded}
			sendErr := errors.New("client gone")
			stream := &railRecordingStream[pb.RespTraDelay]{ctx: t.Context(), sendError: sendErr}
			err := tc.invoke(source, stream)
			if !errors.Is(err, sendErr) || len(stream.messages) != 1 || !proto.Equal(stream.messages[0].Data, want) {
				t.Fatalf("stream messages=%v, error=%v", stream.messages, err)
			}
			if source.channel != tc.channel || len(source.keys) != 1 || source.keys[0] != tc.channel || !source.closed {
				t.Fatalf("stream routing=%+v", source)
			}
			if len(source.demand) != 1 || source.demand[0] != shared.LiveDemandKey("tra", "TRA") {
				t.Fatalf("TRA stream demand=%v", source.demand)
			}
			source = &railLiveSource{payload: []byte{0xff}}
			stream = &railRecordingStream[pb.RespTraDelay]{ctx: t.Context()}
			if err := tc.invoke(source, stream); status.Code(err) != codes.Internal || len(stream.messages) != 0 || !source.closed {
				t.Fatalf("malformed seed error=%v, messages=%v", err, stream.messages)
			}
		})
	}
}

func TestTHSRSeatsStreamUsesDatePatternAndRejectsMalformedSeed(t *testing.T) {
	want := &pb.ThsrAvailableSeats{TrainNo: "123"}
	encoded, err := proto.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	source := &railLiveSource{payload: encoded}
	sendErr := errors.New("client gone")
	stream := &railRecordingStream[pb.RespThsrSeats]{ctx: t.Context(), sendError: sendErr}
	server := &ThsrServer{live: source}
	req := &pb.Ask_Thsr{Date: "2026-07-18T08:00:00+08:00"}
	err = server.AvailableSeats(req, stream)
	pattern := shared.ThsrSeatsPattern("2026-07-18")
	if !errors.Is(err, sendErr) || len(stream.messages) != 1 || !proto.Equal(stream.messages[0].Data, want) {
		t.Fatalf("seat stream messages=%v, error=%v", stream.messages, err)
	}
	if source.channel != pattern || source.pattern != pattern || len(source.keys) != 1 || source.keys[0] != "seat-key" || !source.closed {
		t.Fatalf("seat stream routing=%+v", source)
	}
	if len(source.demand) != 1 || source.demand[0] != shared.LiveDemandKey("thsr_seats", "THSR") {
		t.Fatalf("seat stream demand=%v", source.demand)
	}
	source = &railLiveSource{payload: []byte{0xff}}
	stream = &railRecordingStream[pb.RespThsrSeats]{ctx: t.Context()}
	server.live = source
	if err := server.AvailableSeats(req, stream); status.Code(err) != codes.Internal || len(stream.messages) != 0 || !source.closed {
		t.Fatalf("malformed seats error=%v, messages=%v", err, stream.messages)
	}
}
