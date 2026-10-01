package metro

import (
	"context"
	"strings"
	"testing"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// undirectedAdjacency builds a both-directions map the way the loader stores
// mrt_adjacency, so BFS walks it as an undirected line graph.
func undirectedAdjacency(edges [][2]string) map[string][]string {
	adjacency := map[string][]string{}
	for _, e := range edges {
		adjacency[e[0]] = append(adjacency[e[0]], e[1])
		adjacency[e[1]] = append(adjacency[e[1]], e[0])
	}
	return adjacency
}

func TestMrtBFSPath(t *testing.T) {
	// A line with a branch at O13: main O12→O13→O14, branch O13→O50.
	adjacency := undirectedAdjacency([][2]string{
		{"O12", "O13"}, {"O13", "O14"}, {"O13", "O50"},
	})
	cases := []struct {
		name        string
		board, term string
		want        []string
		wantOK      bool
	}{
		{"linear", "O12", "O14", []string{"O12", "O13", "O14"}, true},
		{"branch", "O12", "O50", []string{"O12", "O13", "O50"}, true},
		{"reverse", "O14", "O12", []string{"O14", "O13", "O12"}, true},
		{"same station", "O12", "O12", nil, false},
		{"unreachable other line", "O12", "BL15", nil, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := mrtBFSPath(adjacency, c.board, c.term)
			if ok != c.wantOK {
				t.Fatalf("ok = %v want %v", ok, c.wantOK)
			}
			if !equalStrings(got, c.want) {
				t.Errorf("path = %v want %v", got, c.want)
			}
		})
	}
}

func TestMrtTargetIndex(t *testing.T) {
	path := []string{"O12", "O13", "O14", "O15"}
	cases := []struct {
		target string
		want   int32
		ok     bool
	}{
		{"O13", 1, true},
		{"O15", 3, true},
		{"O12", 0, false}, // the board itself is not "ahead"
		{"O99", 0, false}, // not on the path
	}
	for _, c := range cases {
		got, ok := mrtTargetIndex(path, c.target)
		if got != c.want || ok != c.ok {
			t.Errorf("mrtTargetIndex(%q) = %d,%v want %d,%v", c.target, got, ok, c.want, c.ok)
		}
	}
}

func TestCreateTrackValidation(t *testing.T) {
	server := &MrtServer{}
	base := &pb.CreateMrtTrackRequest{
		InstallId: "install-1", CarId: "1021", BoardStationId: "BL12",
		DestStationId: "BL17", TargetStationId: "BL15", LeadStops: 2, System: "TRTC",
	}
	clone := func(mutate func(*pb.CreateMrtTrackRequest)) *pb.CreateMrtTrackRequest {
		r := proto.Clone(base).(*pb.CreateMrtTrackRequest)
		mutate(r)
		return r
	}
	cases := []struct {
		name string
		req  *pb.CreateMrtTrackRequest
		code codes.Code
	}{
		{"missing car", clone(func(r *pb.CreateMrtTrackRequest) { r.CarId = "" }), codes.InvalidArgument},
		{"missing target", clone(func(r *pb.CreateMrtTrackRequest) { r.TargetStationId = "" }), codes.InvalidArgument},
		{"non-TRTC system", clone(func(r *pb.CreateMrtTrackRequest) { r.System = "KRTC" }), codes.FailedPrecondition},
		{"lead too low", clone(func(r *pb.CreateMrtTrackRequest) { r.LeadStops = -1 }), codes.InvalidArgument},
		{"lead too high", clone(func(r *pb.CreateMrtTrackRequest) { r.LeadStops = 121 }), codes.InvalidArgument},
		// The card's display strings are rendered on a system notification, so
		// they are bounded here rather than trusted.
		{"line label too long", clone(func(r *pb.CreateMrtTrackRequest) {
			r.VehicleLabel = strings.Repeat("線", 65)
		}), codes.InvalidArgument},
		{"colour not hex", clone(func(r *pb.CreateMrtTrackRequest) {
			r.LineColorHex = "rgb(0,112,189)"
		}), codes.InvalidArgument},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := server.CreateTrack(context.Background(), c.req)
			if status.Code(err) != c.code {
				t.Errorf("CreateTrack() code = %v want %v (err=%v)", status.Code(err), c.code, err)
			}
		})
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestValidHexColor(t *testing.T) {
	for _, ok := range []string{"", "#0070BD", "#ffdb00"} {
		if !validHexColor(ok) {
			t.Errorf("validHexColor(%q) = false", ok)
		}
	}
	for _, bad := range []string{"0070BD", "#0070B", "#0070BDD", "#00-0BD", "rgb(0,1,2)"} {
		if validHexColor(bad) {
			t.Errorf("validHexColor(%q) = true", bad)
		}
	}
}

func TestValidPushToken(t *testing.T) {
	// Empty is the clear. Anything non-hex never reaches Apple, so it is
	// rejected at the door rather than stored and retried every station hop.
	for _, ok := range []string{"", "deadBEEF00", strings.Repeat("a", 256)} {
		if !validPushToken(ok) {
			t.Errorf("validPushToken(%q…) = false", ok[:min(len(ok), 12)])
		}
	}
	for _, bad := range []string{"not-a-token", "zz", strings.Repeat("a", 257)} {
		if validPushToken(bad) {
			t.Errorf("validPushToken(%q…) = true", bad[:min(len(bad), 12)])
		}
	}
}

func TestSetTrackPushTokenValidation(t *testing.T) {
	server := &MrtServer{}
	cases := []struct {
		name string
		req  *pb.SetMrtTrackPushTokenRequest
	}{
		{"missing install", &pb.SetMrtTrackPushTokenRequest{TrackId: "t1", PushToken: "ab"}},
		{"missing track", &pb.SetMrtTrackPushTokenRequest{InstallId: "install-1", PushToken: "ab"}},
		{"token not hex", &pb.SetMrtTrackPushTokenRequest{InstallId: "install-1", TrackId: "t1", PushToken: "nope!"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// Rejected before any store or Redis call, which is what lets this
			// run against a zero-value server.
			_, err := server.SetTrackPushToken(context.Background(), c.req)
			if status.Code(err) != codes.InvalidArgument {
				t.Errorf("SetTrackPushToken() code = %v want InvalidArgument (err=%v)", status.Code(err), err)
			}
		})
	}
}
