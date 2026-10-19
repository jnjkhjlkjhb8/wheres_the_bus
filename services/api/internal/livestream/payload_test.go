package livestream

import (
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestDecodePayloadPreservesMessage(t *testing.T) {
	want := &pb.NearStation{StationID: "station", StationName: "Station", Walk: 2}
	data, err := proto.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	target := &pb.NearStation{}
	got, err := DecodePayload(data, target)
	if err != nil || got != target || !proto.Equal(got, want) {
		t.Fatalf("decoded = %v, err %v, want %v in original target", got, err, want)
	}
}

func TestDecodePayloadRejectsMalformedWireData(t *testing.T) {
	target := &pb.NearStation{}
	got, err := DecodePayload([]byte{0xff}, target)
	if got != target || status.Code(err) != codes.Internal {
		t.Fatalf("decoded = %v, err %v, want original target and Internal", got, err)
	}
}
