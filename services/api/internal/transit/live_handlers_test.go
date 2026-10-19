package transit

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type transitSeedSource struct {
	key     string
	payload []byte
	demand  string
	ttl     time.Duration
}

func (s *transitSeedSource) Get(_ context.Context, key string) ([]byte, bool) {
	return s.payload, key == s.key
}
func (*transitSeedSource) ScanKeys(context.Context, string) []string { return nil }
func (s *transitSeedSource) Subscribe(_ context.Context, key string) (<-chan []byte, func(), error) {
	if key != s.key {
		return nil, nil, errors.New("unexpected stream channel")
	}
	return make(chan []byte), func() {}, nil
}
func (s *transitSeedSource) Touch(_ context.Context, key string, ttl time.Duration) {
	s.demand = key
	s.ttl = ttl
}

type transitTestStream[T proto.Message] struct {
	grpc.ServerStream
	ctx  context.Context
	want T
	t    *testing.T
	err  error
}

func (s *transitTestStream[T]) Context() context.Context { return s.ctx }
func (s *transitTestStream[T]) Send(got T) error {
	if !proto.Equal(got, s.want) {
		s.t.Fatalf("live response = %v, want %v", got, s.want)
	}
	return s.err
}

func TestTransitLiveStreamsUseRequestedKeyAndClaimDemand(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	sendErr := errors.New("client disconnected")
	bus := &pb.Bus_RouteArrival{SubRouteUid: "TPE-route"}
	busData, err := proto.Marshal(bus)
	if err != nil {
		t.Fatal(err)
	}
	busSource := &transitSeedSource{key: shared.BusRouteEtaKey("TPE-route"), payload: busData}
	busStream := &transitTestStream[*pb.Resp_BusEta]{ctx: ctx, want: &pb.Resp_BusEta{Data: bus}, t: t, err: sendErr}
	if err := NewBusRouteServer(nil, nil, nil, busSource).Eta(&pb.Bus_Ask_Route{SubRouteUID: "TPE-route"}, busStream); !errors.Is(err, sendErr) {
		t.Fatalf("bus stream error = %v", err)
	}
	if busSource.demand != shared.LiveDemandKey("bus_eta", "Taipei") || busSource.ttl != 10*time.Minute {
		t.Fatalf("bus demand = %q, TTL %v", busSource.demand, busSource.ttl)
	}
	bike := &pb.BikeEta{StationUID: "TPE-bike", GeneralBikes: 4}
	bikeData, err := proto.Marshal(bike)
	if err != nil {
		t.Fatal(err)
	}
	bikeSource := &transitSeedSource{key: shared.BikeAvailabilityKey("TPE-bike"), payload: bikeData}
	bikeStream := &transitTestStream[*pb.Resp_BikeEta]{ctx: ctx, want: &pb.Resp_BikeEta{Data: bike}, t: t, err: sendErr}
	if err := NewBikeServer(nil, nil, nil, bikeSource).Eta(&pb.BikeRequest{StationUID: "TPE-bike"}, bikeStream); !errors.Is(err, sendErr) {
		t.Fatalf("bike stream error = %v", err)
	}
	if bikeSource.demand != shared.LiveDemandKey("bike", "Taipei") {
		t.Fatalf("bike demand = %q", bikeSource.demand)
	}
}

func TestStationGroupReadAndLiveCityResolution(t *testing.T) {
	db, rc := transitTestServices(t)
	uid := fmt.Sprintf("quality-station-group-%d", os.Getpid())
	if _, err := db.Exec(t.Context(), `INSERT INTO bus_station_groups(group_uid,group_id,group_name,city,position,source) VALUES($1,$1,'測試站','Taipei',ST_SetSRID(ST_MakePoint(121.5,25),4326),'quality')`, uid); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = db.Exec(context.Background(), "DELETE FROM bus_station_groups WHERE group_uid=$1", uid) })
	if _, err := db.Exec(t.Context(), `INSERT INTO bus_station_group_members(station_uid,group_uid,station_id,station_name,city,position) VALUES($1,$2,'2','第二站','Taipei',ST_SetSRID(ST_MakePoint(121.6,25),4326)),($3,$2,'1','第一站','Taipei',ST_SetSRID(ST_MakePoint(121.5,25),4326))`, uid+"-2", uid, uid+"-1"); err != nil {
		t.Fatal(err)
	}
	stationArrival := &pb.Bus_StationArrival{StationName: "測試站"}
	payload, err := proto.Marshal(stationArrival)
	if err != nil {
		t.Fatal(err)
	}
	source := &transitSeedSource{key: shared.BusStationEtaKey("Taipei", uid), payload: payload}
	server := NewBusStationServer(db, rc, source)
	got, err := server.Group(t.Context(), &pb.Bus_Ask_StationGroup{GroupUid: uid})
	if err != nil || got.GroupUid != uid || got.City != "Taipei" || got.GroupName != "測試站" || got.PositionLon != 121.5 || got.PositionLat != 25 || len(got.Members) != 2 || got.Members[0].StationId != "1" || got.Members[1].StationId != "2" {
		t.Fatalf("station group = %v, error %v", got, err)
	}
	if _, err := server.Group(t.Context(), &pb.Bus_Ask_StationGroup{}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("empty group error = %v", err)
	}
	if _, err := server.Group(t.Context(), &pb.Bus_Ask_StationGroup{GroupUid: uid + "-missing"}); status.Code(err) != codes.NotFound {
		t.Fatalf("missing group error = %v", err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	sendErr := errors.New("station subscriber disconnected")
	stream := &transitTestStream[*pb.Resp_BusStationEta]{ctx: ctx, want: &pb.Resp_BusStationEta{Data: stationArrival}, t: t, err: sendErr}
	if err := server.Eta(&pb.Bus_Ask_StationGroup{GroupUid: uid}, stream); !errors.Is(err, sendErr) {
		t.Fatalf("station ETA error = %v", err)
	}
	if source.demand != shared.LiveDemandKey("bus_eta", "Taipei") {
		t.Fatalf("station demand = %q", source.demand)
	}
	for _, in := range []*pb.Bus_Ask_StationGroup{{}, {GroupUid: "unknown"}} {
		if err := streamBusStationEta(nil, source, in, stream); status.Code(err) != codes.InvalidArgument {
			t.Fatalf("incomplete station ETA error = %v", err)
		}
	}
}
