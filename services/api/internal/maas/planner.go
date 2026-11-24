package maas

import (
	"context"
	"crypto/sha256"
	"fmt"
	"net/url"
	"strconv"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/ratelimit"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// PlannerServer answers PlannerService on MaasServer's MOTIS client, cache,
// work slots and shutdown gate, so both contracts share one budget. It charges
// MaasService's per-caller quota itself, on a cache miss only: a sort change
// is answered from cache and must not spend the allowance for MOTIS work.
type PlannerServer struct {
	pb.UnimplementedPlannerServiceServer

	maas    *MaasServer
	limiter *ratelimit.Limiter
	quota   MaasResourceConfig
}

func NewPlannerServer(maas *MaasServer, limiter *ratelimit.Limiter, quota MaasResourceConfig) *PlannerServer {
	return &PlannerServer{maas: maas, limiter: limiter, quota: quota}
}

var _plannerAccessModes = map[pb.PlannerAccessMode]int32{
	pb.PlannerAccessMode_PLANNER_ACCESS_MODE_BIKE:        1,
	pb.PlannerAccessMode_PLANNER_ACCESS_MODE_CAR:         2,
	pb.PlannerAccessMode_PLANNER_ACCESS_MODE_SHARED_BIKE: 3,
}

// _plannerModeIDs maps onto MaasPlanRequest's mode ids so both contracts send
// MOTIS the same mode filter.
var _plannerModeIDs = map[pb.PlannerTransitMode]int32{
	pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_HIGH_SPEED_RAIL: 3,
	pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_RAIL:            4,
	pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_BUS:             5,
	pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_COACH:           5,
	pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_SUBWAY:          6,
	pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_TRAM:            7,
	pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_FERRY:           8,
	pb.PlannerTransitMode_PLANNER_TRANSIT_MODE_CABLE_CAR:       9,
}

func (p *PlannerServer) Plan(ctx context.Context, req *pb.PlannerRequest) (*pb.PlannerResponse, error) {
	full, err := p.run(ctx, req, func(*pb.PlannerResponse) error { return nil })
	if err != nil {
		return nil, err
	}
	return rankPlanner(full, req), nil
}

func (p *PlannerServer) PlanStream(req *pb.PlannerRequest, stream pb.PlannerService_PlanStreamServer) error {
	full, err := p.run(stream.Context(), req, func(routes *pb.PlannerResponse) error {
		return stream.Send(&pb.PlannerUpdate{Plan: rankPlanner(routes, req)})
	})
	if err != nil {
		return err
	}
	return stream.Send(&pb.PlannerUpdate{Plan: rankPlanner(full, req), Complete: true})
}

// run returns every itinerary MOTIS gave, unranked: the cache holds that set,
// so changing the sort is answered without asking MOTIS again. routesReady
// sees the itineraries before their geometry is paid for, and only on a cache
// miss.
func (p *PlannerServer) run(ctx context.Context, req *pb.PlannerRequest, routesReady func(*pb.PlannerResponse) error) (*pb.PlannerResponse, error) {
	if len(req.GetTransitModes()) > maxTransitModes {
		return nil, status.Error(codes.InvalidArgument, "too many transit modes")
	}
	if !p.maas.beginSharedFlight() {
		return nil, errMaasServerClosing
	}
	defer p.maas.endSharedFlight()
	// Unlike MaasService.plan there is no singleflight: the work has one
	// caller, so a caller that hangs up cancels it.
	workCtx, cancel := context.WithTimeout(p.maas.lifecycleCtx, p.maas.workTimeout)
	defer cancel()
	defer context.AfterFunc(ctx, cancel)()
	// The caller's context, not workCtx, carries the peer the quota is keyed
	// by.
	charge := func() error { return maasPlanQuota(ctx, p.limiter, p.quota) }
	return p.slotted(workCtx, req, charge, routesReady)
}

func (p *PlannerServer) slotted(ctx context.Context, req *pb.PlannerRequest, charge func() error, routesReady func(*pb.PlannerResponse) error) (*pb.PlannerResponse, error) {
	release, err := p.maas.acquireWorkSlot()
	if err != nil {
		return nil, err
	}
	defer release()
	key := plannerKey(req)
	var cached pb.PlannerResponse
	if p.maas.loadCached(ctx, key, &cached) {
		return &cached, nil
	}
	if err := admitMiss(ctx, charge); err != nil {
		return nil, err
	}
	return p.fresh(ctx, key, req, routesReady)
}

// admitMiss lets a cache miss through to MOTIS once the work is still live
// and the caller's quota allows it.
func admitMiss(ctx context.Context, charge func() error) error {
	if err := workDone(ctx); err != nil {
		return status.FromContextError(err).Err()
	}
	return charge()
}

func (p *PlannerServer) fresh(ctx context.Context, key string, req *pb.PlannerRequest, routesReady func(*pb.PlannerResponse) error) (*pb.PlannerResponse, error) {
	plan, err := p.maas.motisClient.fetch(ctx, plannerQuery(req, time.Now()))
	if err != nil {
		return nil, maasPlanError(err)
	}
	full, err := p.build(ctx, plan, plannerTransferBuffer(req)*60, routesReady)
	if err != nil {
		return nil, err
	}
	p.maas.cachePlan(ctx, key, full)
	return full, nil
}

// build reads fares, notification identities and map geometry off the
// MaasService conversion of the same itineraries, so the two contracts cannot
// price or draw one itinerary differently.
func (p *PlannerServer) build(ctx context.Context, plan *motisPlanResponse, bufferSeconds int64, routesReady func(*pb.PlannerResponse) error) (*pb.PlannerResponse, error) {
	api, geometry := convertMotisItineraries(plan.Itineraries)
	legacy, refs := convertRoutes(ctx, p.maas.db, api)
	full, pairs := plannerResponse(plan, legacy)
	addPlannerTransfers(full, estimatedLegs(ctx, p.maas.db, pairs), bufferSeconds)
	if err := routesReady(full); err != nil {
		return nil, err
	}
	p.maas.enrich(ctx, refs, geometry)
	copyPlannerGeometry(pairs)
	return full, nil
}

// plannerQuery leaves MaasPlanRequest's minimum transfer time at 0 and asks
// for the buffer instead: MOTIS stretches a transfer walk to
// additionalTransferTime + walk, which the buffer can be subtracted from, but
// to max(minTransferTime, walk), which hides the walk.
func plannerQuery(req *pb.PlannerRequest, now time.Time) url.Values {
	query := motisPlanQuery(legacyPlanRequest(req), now)
	query.Set("additionalTransferTime", strconv.FormatInt(plannerTransferBuffer(req), 10))
	return query
}

func plannerTransferBuffer(req *pb.PlannerRequest) int64 {
	return int64(clampInt(req.GetTransferBufferMinutes(), 0, 60, 0))
}

func legacyPlanRequest(req *pb.PlannerRequest) *pb.MaasPlanRequest {
	date, clock := plannerClock(req.GetTime())
	modes := make([]int32, 0, len(req.GetTransitModes()))
	for _, mode := range req.GetTransitModes() {
		modes = append(modes, _plannerModeIDs[mode])
	}
	return &pb.MaasPlanRequest{
		FromLat: req.GetFrom().GetLat(), FromLon: req.GetFrom().GetLng(),
		ToLat: req.GetTo().GetLat(), ToLon: req.GetTo().GetLng(),
		Date: date, Time: clock, ArriveBy: req.GetArriveBy(),
		TransitModes: modes, Top: req.GetTop(),
		FirstMileMode: _plannerAccessModes[req.GetFirstMileMode()], FirstMileTime: req.GetFirstMileMinutes(),
		LastMileMode: _plannerAccessModes[req.GetLastMileMode()], LastMileTime: req.GetLastMileMinutes(),
		Wheelchair: req.GetWheelchair(), WalkSpeedCmPerSec: req.GetWalkSpeedCmPerSec(),
		MaxTransfers: req.MaxTransfers, AvoidReservation: req.GetAvoidReservation(),
		CarryBike: req.GetCarryBike(), PageCursor: req.GetPageCursor(),
		LegAlternatives: req.GetLegAlternatives(),
	}
}

// plannerClock restates the request time as the local date and clock the
// MaasPlanRequest carries; none leaves both empty, which plans from now.
func plannerClock(at *timestamppb.Timestamp) (string, string) {
	if at == nil {
		return "", ""
	}
	local := at.AsTime().In(time.Local)
	return local.Format(time.DateOnly), local.Format(time.TimeOnly)
}

// plannerKey leaves the sort out: every sort orders the same cached set.
func plannerKey(req *pb.PlannerRequest) string {
	keyed := proto.CloneOf(req)
	keyed.Sort = pb.PlannerSort_PLANNER_SORT_UNSPECIFIED
	// A request that reached the handler already unmarshalled, so it marshals.
	encoded, _ := proto.MarshalOptions{Deterministic: true}.Marshal(keyed)
	sum := sha256.Sum256(encoded)
	return fmt.Sprintf("planner:plan:v1:%x", sum[:16])
}
