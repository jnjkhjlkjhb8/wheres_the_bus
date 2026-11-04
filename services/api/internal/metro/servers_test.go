package metro

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type metroSource struct {
	key     string
	pattern string
	channel string
	payload []byte
}

func (s *metroSource) Get(_ context.Context, key string) ([]byte, bool) {
	return s.payload, key == s.key
}
func (s *metroSource) ScanKeys(_ context.Context, pattern string) []string {
	if pattern == s.pattern {
		return []string{s.key}
	}
	return nil
}
func (s *metroSource) Subscribe(_ context.Context, channel string) (<-chan []byte, func(), error) {
	if channel != s.channel {
		return nil, nil, errors.New("incorrect channel")
	}
	return make(chan []byte), func() {}, nil
}
func (s *metroSource) Touch(context.Context, string, time.Duration) {}

type metroEtaStream struct {
	grpc.ServerStream
	ctx     context.Context
	want    *pb.MrtLive
	t       *testing.T
	sendErr error
}

func (s *metroEtaStream) Context() context.Context { return s.ctx }
func (s *metroEtaStream) Send(value *pb.Resp_MrtEta) error {
	if !proto.Equal(value.Data, s.want) {
		s.t.Fatalf("arrival = %v, want %v", value.Data, s.want)
	}
	return s.sendErr
}

func TestMetroEtaStreamsSeedFromRequestedStation(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	want := &pb.MrtLive{}
	// An unknown field makes the seed nonempty while retaining a valid protobuf.
	want.ProtoReflect().SetUnknown([]byte{0xf8, 0x07, 0x01})
	payload, err := proto.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	source := &metroSource{key: "seed", pattern: shared.MrtLiveSeedPattern("TRTC", "BL12"), channel: shared.MrtLiveChannel("TRTC", "BL12"), payload: payload}
	sendErr := errors.New("client disconnected")
	stream := &metroEtaStream{ctx: ctx, want: want, t: t, sendErr: sendErr}
	server := NewMrtServer(nil, nil, source, nil)
	if err := server.Eta(&pb.AskMrt{System: "TRTC", StationID: "_BL12_"}, stream); !errors.Is(err, sendErr) {
		t.Fatalf("arrival stream error = %v, want send error", err)
	}
}

type metroTrackStream struct {
	grpc.ServerStream
	ctx     context.Context
	want    *pb.MrtTrackState
	t       *testing.T
	sendErr error
}

func (s *metroTrackStream) Context() context.Context { return s.ctx }
func (s *metroTrackStream) Send(value *pb.MrtTrackState) error {
	if !proto.Equal(value, s.want) {
		s.t.Fatalf("track = %v, want %v", value, s.want)
	}
	return s.sendErr
}

func TestMetroWatchTrackValidationAndSeed(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	want := &pb.MrtTrackState{TrackId: "track-1"}
	payload, err := proto.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	source := &metroSource{key: shared.MrtTrackKey("track-1"), channel: shared.MrtTrackChannel("track-1"), payload: payload}
	sendErr := errors.New("client disconnected")
	stream := &metroTrackStream{ctx: ctx, want: want, t: t, sendErr: sendErr}
	server := NewMrtServer(nil, nil, source, nil)
	if err := server.WatchTrack(&pb.WatchMrtTrackRequest{}, stream); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("empty track error = %v, want InvalidArgument", err)
	}
	if err := server.WatchTrack(&pb.WatchMrtTrackRequest{TrackId: "track-1"}, stream); !errors.Is(err, sendErr) {
		t.Fatalf("track stream error = %v, want send error", err)
	}
}

func TestMetroEtaRejectsGlobAndOversizedRequests(t *testing.T) {
	server := NewMrtServer(nil, nil, &metroSource{}, nil)
	stream := &metroEtaStream{ctx: t.Context(), t: t}
	for name, req := range map[string]*pb.AskMrt{
		"glob system":   {System: "*", StationID: "BL12"},
		"glob station":  {System: "TRTC", StationID: "*"},
		"bracket":       {System: "TRTC", StationID: "BL[0-9]"},
		"empty system":  {System: "", StationID: "BL12"},
		"long system":   {System: strings.Repeat("A", 17), StationID: "BL12"},
		"too many":      {System: "TRTC", StationID: strings.Repeat("BL12_", maxMrtEtaStations+1)},
		"key separator": {System: "TRTC", StationID: "BL12:x"},
	} {
		if err := server.Eta(req, stream); status.Code(err) != codes.InvalidArgument {
			t.Errorf("%s: error = %v, want InvalidArgument", name, err)
		}
	}
}

func TestMetroEtaStationsKeepsTransferStationIDs(t *testing.T) {
	got, err := mrtEtaStations("TRTC", "_BL12_R10_")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, ",") != "BL12,R10" {
		t.Fatalf("stations = %v, want [BL12 R10]", got)
	}
	if _, err := mrtEtaStations("TRTC", strings.TrimSuffix(strings.Repeat("BL12_", maxMrtEtaStations), "_")); err != nil {
		t.Fatalf("stations at cap rejected: %v", err)
	}
}
