package maas

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/jackc/pgx/v5"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"golang.org/x/sync/singleflight"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type MaasServer struct {
	pb.UnimplementedMaasServiceServer

	cache       MaasCache
	db          maasDB
	maasClient  *resty.Client
	motisClient *motisClient
	health      *PlannerHealthMonitor
	osrmClient  *resty.Client
	sfGroup     singleflight.Group
	workSlots   chan struct{}
	workTimeout time.Duration

	// lifecycleCtx is the parent of every shared singleflight closure's
	// bounded work context. Close cancels it so in-flight cache/upstream I/O
	// unblocks promptly instead of running out its full workTimeout.
	lifecycleCtx    context.Context
	lifecycleCancel context.CancelFunc

	// mu guards closing and gates sharedWork.Add so a new closure can never
	// start registering after Close has begun waiting for the ones already
	// registered (the standard Add-before-Wait race).
	mu         sync.Mutex
	closing    bool
	sharedWork sync.WaitGroup
}

// errMaasServerClosing is returned by a singleflight closure that observed
// the server closing before starting any cache or upstream work, so new work
// fails promptly instead of racing shutdown.
var errMaasServerClosing = status.Error(codes.Unavailable, "MaaS server is shutting down")

// errMaasNoRoute marks a TDX MaaS 404: the upstream has no itinerary for this
// origin/destination pair. That is an empty result rather than a router
// failure, so Plan logs it at Warn instead of raising an error issue.
var errMaasNoRoute = errors.New("TDX MaaS has no route for this origin/destination")

type maasDB interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

type MaasCache interface {
	Get(context.Context, string) ([]byte, error)
	Set(context.Context, string, []byte, time.Duration) error
}

type RedisMaasCache struct{ client *redis.Client }

func NewRedisMaasCache(opts *redis.Options) *RedisMaasCache {
	cloned := *opts
	return &RedisMaasCache{client: redis.NewClient(&cloned)}
}

func redisContextError(ctx context.Context, err error) error {
	if err == nil {
		return nil
	}
	if contextErr := ctx.Err(); contextErr != nil {
		return contextErr
	}
	deadline, hasDeadline := ctx.Deadline()
	var timeoutError net.Error
	if hasDeadline && !time.Now().Before(deadline) && errors.As(err, &timeoutError) && timeoutError.Timeout() {
		// The socket deadline and context deadline are the same instant. The
		// socket can wake just before the context timer goroutine records Err().
		return context.DeadlineExceeded
	}
	return err
}

func (c *RedisMaasCache) Get(ctx context.Context, key string) ([]byte, error) {
	value, err := c.client.Get(ctx, key).Bytes()
	return value, redisContextError(ctx, err)
}

func (c *RedisMaasCache) Set(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	return redisContextError(ctx, c.client.Set(ctx, key, value, ttl).Err())
}

func (c *RedisMaasCache) Close() error {
	return c.client.Close()
}

type maasSharedWorkConfig struct {
	MaxConcurrent int
	Timeout       time.Duration
	// Motis is the planner when set, and nil selects the TDX proxy.
	Motis  *motisClient
	Health *PlannerHealthMonitor
}

var DefaultMaasSharedWorkConfig = maasSharedWorkConfig{
	MaxConcurrent: 4,
	Timeout:       20 * time.Second,
}

const _maasOSRMConcurrency = 4

// How long a finished plan stays in Redis. Short: an itinerary quotes live
// departure times, so a stale hit would hand a rider a bus that has left.
const _maasCacheTTL = 90 * time.Second

func shouldRetryMaas(resp *resty.Response, err error) bool {
	if err != nil {
		return !errors.Is(err, context.Canceled) &&
			!errors.Is(err, context.DeadlineExceeded) &&
			!shared.IsTDXAuthError(err)
	}
	return resp != nil && (resp.StatusCode() == http.StatusTooManyRequests || resp.StatusCode() == http.StatusServiceUnavailable)
}

func NewMaasServerWithCache(cache MaasCache, db maasDB, tdx *shared.TDXClient, workConfig maasSharedWorkConfig) *MaasServer {
	c := tdx.NewAuthedClient("https://tdx.transportdata.tw/api/maas").
		SetHeader("Content-Type", "application/json").
		SetRetryCount(3).
		SetRetryWaitTime(500 * time.Millisecond).
		AddRetryCondition(shouldRetryMaas)
	if workConfig.MaxConcurrent <= 0 {
		workConfig.MaxConcurrent = DefaultMaasSharedWorkConfig.MaxConcurrent
	}
	if workConfig.Timeout <= 0 {
		workConfig.Timeout = DefaultMaasSharedWorkConfig.Timeout
	}
	lifecycleCtx, cancel := context.WithCancel(context.Background())
	return &MaasServer{
		cache: cache, db: db, maasClient: c,
		motisClient: workConfig.Motis, health: workConfig.Health,
		osrmClient: resty.New().SetTimeout(5 * time.Second),
		workSlots:  make(chan struct{}, workConfig.MaxConcurrent), workTimeout: workConfig.Timeout,
		lifecycleCtx: lifecycleCtx, lifecycleCancel: cancel,
	}
}

func (s *MaasServer) beginSharedFlight() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closing {
		return false
	}
	s.sharedWork.Add(1)
	return true
}

func (s *MaasServer) endSharedFlight() {
	s.sharedWork.Done()
}

func (s *MaasServer) Close() {
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return
	}
	s.closing = true
	s.mu.Unlock()
	s.lifecycleCancel()
	s.sharedWork.Wait()
}

type tdxRoute struct {
	TravelTime int64        `json:"travel_time"`
	StartTime  string       `json:"start_time"`
	EndTime    string       `json:"end_time"`
	Transfers  int32        `json:"transfers"`
	Sections   []tdxSection `json:"sections"`
}
type tdxSection struct {
	Type              string       `json:"type"`
	TravelSummary     tdxSummary   `json:"travelSummary"`
	Departure         tdxPlaceInfo `json:"departure"`
	Arrival           tdxPlaceInfo `json:"arrival"`
	Transport         tdxTransport `json:"transport"`
	IntermediateStops []tdxStop    `json:"intermediateStops"`
	Agency            tdxAgency    `json:"agency"`
	// Services that could replace this leg. MOTIS-only and never part of a TDX
	// payload, hence the ignored tag: TDX has no equivalent, so unmarshalling
	// must not go looking for one.
	Alternatives []tdxSection `json:"-"`
}
type tdxSummary struct {
	Duration int64   `json:"duration"`
	Length   float64 `json:"length"`
}
type tdxPlaceInfo struct {
	Time  string   `json:"time"`
	Place tdxPlace `json:"place"`
}
type tdxPlace struct {
	Name     string      `json:"name"`
	Type     string      `json:"type"`
	Location tdxLocation `json:"location"`
}
type tdxLocation struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}
type tdxTransport struct {
	Mode       string `json:"mode"`
	Name       string `json:"name"`
	ShortName  string `json:"shortName"`
	Number     string `json:"number"`
	LongName   string `json:"longName"`
	Headsign   string `json:"headsign"`
	Category   string `json:"category"`
	RouteColor string `json:"route_color"`
}
type tdxStop struct {
	Departure tdxPlaceInfo `json:"departure"`
}
type tdxAgency struct {
	AgencyID string `json:"agency_id"`
	Name     string `json:"name"`
	Website  string `json:"website"`
	Phone    string `json:"phone"`
}
type tdxAPIResponse struct {
	Result string `json:"result"`
	Data   struct {
		Routes []tdxRoute `json:"routes"`
	} `json:"data"`
}

func (s *MaasServer) Plan(ctx context.Context, req *pb.MaasPlanRequest) (*pb.MaasPlanResponse, error) {
	cacheKey := maasKey(req)
	result := s.sfGroup.DoChan(cacheKey, func() (any, error) {
		if !s.beginSharedFlight() {
			return nil, errMaasServerClosing
		}
		defer s.endSharedFlight()
		return s.runSharedPlan(cacheKey, req)
	})
	select {
	case <-ctx.Done():
		return nil, status.FromContextError(ctx.Err()).Err()
	case completed := <-result:
		if completed.Err != nil {
			return nil, maasPlanError(completed.Err)
		}
		resp, ok := completed.Val.(*pb.MaasPlanResponse)
		if !ok {
			return nil, status.Error(codes.Internal, "unexpected plan result type")
		}
		return resp, nil
	}
}

// maasPlanError maps a planning failure onto the gRPC status both plan entry
// points return. A TDX 404 is an empty result rather than a router fault, so it
// logs at Warn and answers NotFound.
func maasPlanError(err error) error {
	if errors.Is(err, errMaasNoRoute) {
		zap.S().Warnw("no route", "component", "maas", "action", "plan", "event", "no_route", "err", err)
		return status.Error(codes.NotFound, "no route for this origin/destination")
	}
	zap.S().Errorw("plan error", "component", "maas", "err", err)
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return status.FromContextError(err).Err()
	}
	if status.Code(err) != codes.Unknown {
		return err
	}
	return status.Errorf(codes.Unavailable, "route planning unavailable: %v", err)
}

func (s *MaasServer) PlanStream(req *pb.MaasPlanRequest, stream pb.MaasService_PlanStreamServer) error {
	if !s.beginSharedFlight() {
		return errMaasServerClosing
	}
	defer s.endSharedFlight()

	// Bounded like the unary path, and additionally cancelled when the caller
	// hangs up: this work has exactly one client, so a stream that is gone
	// leaves nobody to serve.
	workCtx, cancel := context.WithTimeout(s.lifecycleCtx, s.workTimeout)
	defer cancel()
	defer context.AfterFunc(stream.Context(), cancel)()

	select {
	case s.workSlots <- struct{}{}:
		defer func() { <-s.workSlots }()
	default:
		return status.Error(codes.ResourceExhausted, "MaaS concurrency limit exceeded")
	}

	cacheKey := maasKey(req)
	if cached, err := s.cache.Get(workCtx, cacheKey); err == nil {
		var response pb.MaasPlanResponse
		if err := proto.Unmarshal(cached, &response); err == nil {
			return stream.Send(&pb.MaasPlanUpdate{Plan: &response, Complete: true})
		}
	}
	if err := workCtx.Err(); err != nil {
		return status.FromContextError(err).Err()
	}

	useMotis := s.useMotis()
	plan, err := s.planUpstream(workCtx, req, useMotis)
	if err != nil {
		return maasPlanError(err)
	}
	response, refs := convertRoutes(workCtx, s.db, plan.api)
	response.PreviousPageCursor = plan.previous
	response.NextPageCursor = plan.next
	s.rank(response, req, useMotis)
	if err := stream.Send(&pb.MaasPlanUpdate{Plan: response}); err != nil {
		return err
	}
	s.enrich(workCtx, refs, plan.geometry, useMotis)
	// Cached before the last Send: the work is already paid for, and a client
	// that disconnects during that send should not throw it away.
	s.cachePlan(workCtx, cacheKey, response)
	return stream.Send(&pb.MaasPlanUpdate{Plan: response, Complete: true})
}

// cachePlan stores a finished plan best-effort. The rider already has the
// answer by this point, so a cache failure is logged, never returned.
func (s *MaasServer) cachePlan(ctx context.Context, cacheKey string, response *pb.MaasPlanResponse) {
	encoded, err := proto.Marshal(response)
	if err != nil {
		return
	}
	if err := s.cache.Set(ctx, cacheKey, encoded, _maasCacheTTL); err != nil && ctx.Err() == nil {
		zap.S().Errorw("cache set failed", "component", "maas", "err", err)
	}
}

func (s *MaasServer) runSharedPlan(cacheKey string, req *pb.MaasPlanRequest) (*pb.MaasPlanResponse, error) {
	// Deriving from lifecycleCtx (rather than context.Background) means Close
	// cancels this work immediately instead of leaving it to run out its full
	// workTimeout while shutdown waits on sharedWork.
	workCtx, cancel := context.WithTimeout(s.lifecycleCtx, s.workTimeout)
	defer cancel()
	select {
	case s.workSlots <- struct{}{}:
		defer func() { <-s.workSlots }()
	default:
		return nil, status.Error(codes.ResourceExhausted, "MaaS concurrency limit exceeded")
	}

	cached, err := s.cache.Get(workCtx, cacheKey)
	if err == nil {
		var response pb.MaasPlanResponse
		if err := proto.Unmarshal(cached, &response); err == nil {
			return &response, nil
		}
	}
	if err := workCtx.Err(); err != nil {
		return nil, err
	}

	response, err := s.get(workCtx, req)
	if err != nil {
		return nil, err
	}
	encoded, err := proto.Marshal(response)
	if err != nil {
		return response, nil
	}
	if err := s.cache.Set(workCtx, cacheKey, encoded, _maasCacheTTL); err != nil {
		if contextErr := workCtx.Err(); contextErr != nil {
			return nil, contextErr
		}
		zap.S().Errorw("cache set failed", "component", "maas", "err", err)
	}
	return response, nil
}

func maasTimeParam(date, timeStr string, arriveBy bool, now time.Time) (depart, arrival string) {
	if len(timeStr) == len("HH:mm") {
		timeStr += ":00"
	}
	const layout = "2006-01-02T15:04:05"
	value := fmt.Sprintf("%sT%s", date, timeStr)
	if !arriveBy {
		if t, err := time.ParseInLocation(layout, value, time.Local); err == nil && !t.After(now) {
			value = now.Add(time.Minute).Format(layout)
		}
	}
	return value, value
}

func (s *MaasServer) get(ctx context.Context, req *pb.MaasPlanRequest) (*pb.MaasPlanResponse, error) {
	useMotis := s.useMotis()
	plan, err := s.planUpstream(ctx, req, useMotis)
	if err != nil {
		return nil, err
	}
	out, refs := convertRoutes(ctx, s.db, plan.api)
	out.PreviousPageCursor = plan.previous
	out.NextPageCursor = plan.next
	s.enrich(ctx, refs, plan.geometry, useMotis)
	s.rank(out, req, useMotis)
	return out, nil
}

func (s *MaasServer) useMotis() bool {
	if s.motisClient == nil {
		return false
	}
	if s.health == nil {
		return true
	}
	return s.health.UseMotis()
}

// planUpstream calls whichever planner is configured. The MOTIS path also
// returns the walk geometry it already computed; the TDX path returns nil there
// and pays OSRM for it in [MaasServer.enrich].
func (s *MaasServer) planUpstream(ctx context.Context, req *pb.MaasPlanRequest, useMotis bool) (*motisPlanResult, error) {
	if useMotis {
		return s.motisClient.Plan(ctx, req)
	}
	api, err := s.fetch(ctx, req)
	if err != nil {
		return nil, err
	}
	// TDX returns no walk geometry and does not page, so the result carries the
	// plan and nothing else; the empty cursors are what tell the app not to
	// offer an earlier/later action it cannot honour.
	return &motisPlanResult{api: api}, nil
}

func (s *MaasServer) enrich(ctx context.Context, refs []maasSectionRef, walks []*motisWalkGeometry, useMotis bool) {
	if useMotis {
		if !applyMotisWalkGeometry(refs, walks) {
			zap.S().Errorw("walk geometry mismatch",
				"component", "maas",
				"action", "enrich",
				"event", "geometry_mismatch",
				"sections", len(refs),
				"geometry", len(walks),
			)
		}
		enrichTransitPaths(ctx, s.db, refs)
		return
	}
	enrichGeometry(ctx, s.db, s.osrmClient, refs)
}

// rank applies the rider's price/time preference. Only MOTIS needs it: TDX
// takes gc as a search input and has already ordered its answer.
func (s *MaasServer) rank(out *pb.MaasPlanResponse, req *pb.MaasPlanRequest, useMotis bool) {
	if !useMotis {
		return
	}
	rankMotisRoutes(out, req.Gc, req.Top)
}

// fetch is the upstream TDX MaaS call on its own, so PlanStream can run the two
// conversion stages around it instead of taking the whole thing as one step.
func (s *MaasServer) fetch(ctx context.Context, req *pb.MaasPlanRequest) (*tdxAPIResponse, error) {
	gc := req.Gc
	if gc < 0 || gc > 1 {
		gc = 0.0
	}

	transitModes := req.TransitModes
	if len(transitModes) == 0 {
		transitModes = []int32{3, 4, 5, 6, 7, 8, 9}
	}
	parts := make([]string, len(transitModes))
	for i, m := range transitModes {
		parts[i] = fmt.Sprintf("%d", m)
	}
	transitStr := strings.Join(parts, ",")

	top := clampInt(req.Top, 1, 10, 5)
	tMin := clampInt(req.TransferTimeMin, 0, 60, 15)
	tMax := clampInt(req.TransferTimeMax, 0, 60, 60)
	if tMin > tMax {
		tMin, tMax = tMax, tMin
	}
	firstMode := clampInt(req.FirstMileMode, 0, 3, 0)
	firstTime := clampInt(req.FirstMileTime, 1, 60, 10)
	lastMode := clampInt(req.LastMileMode, 0, 3, 0)
	lastTime := clampInt(req.LastMileTime, 1, 60, 10)

	var apiResp tdxAPIResponse
	r := s.maasClient.R().
		SetContext(ctx).
		SetQueryParam("origin", fmt.Sprintf("%.6f,%.6f", req.FromLat, req.FromLon)).
		SetQueryParam("destination", fmt.Sprintf("%.6f,%.6f", req.ToLat, req.ToLon)).
		SetQueryParam("gc", fmt.Sprintf("%.1f", gc)).
		SetQueryParam("top", fmt.Sprintf("%d", top)).
		SetQueryParam("transit", transitStr).
		SetQueryParam("transfer_time", fmt.Sprintf("%d,%d", tMin, tMax)).
		SetQueryParam("first_mile_mode", fmt.Sprintf("%d", firstMode)).
		SetQueryParam("first_mile_time", fmt.Sprintf("%d", firstTime)).
		SetQueryParam("last_mile_mode", fmt.Sprintf("%d", lastMode)).
		SetQueryParam("last_mile_time", fmt.Sprintf("%d", lastTime)).
		SetResult(&apiResp)
	depart, arrival := maasTimeParam(req.Date, req.Time, req.ArriveBy, time.Now())
	r.SetQueryParam("depart", depart)
	r.SetQueryParam("arrival", arrival)
	resp, err := r.Get("/routing")
	if err != nil {
		return nil, err
	}
	if !resp.IsSuccess() {
		err := _oops.With("status_code", resp.StatusCode()).With("url", resp.Request.URL).With("string", strings.TrimSpace(resp.String())).Errorf("TDX MaaS HTTP")
		if resp.StatusCode() == http.StatusNotFound {
			return nil, _oops.Join(errMaasNoRoute, err)
		}
		return nil, err
	}
	return &apiResp, nil
}

type maasSectionRef struct {
	index  int32
	source tdxSection
	target *pb.Section
	route  *pb.Route
}

func convert(ctx context.Context, db maasDB, osrmClient *resty.Client, api *tdxAPIResponse) *pb.MaasPlanResponse {
	out, refs := convertRoutes(ctx, db, api)
	enrichGeometry(ctx, db, osrmClient, refs)
	return out
}

func convertRoutes(ctx context.Context, db maasDB, api *tdxAPIResponse) (*pb.MaasPlanResponse, []maasSectionRef) {
	out := &pb.MaasPlanResponse{}
	refs := make([]maasSectionRef, 0)
	altRefs := make([]maasSectionRef, 0)
	for _, route := range api.Data.Routes {
		pbRoute := &pb.Route{
			TravelTime: route.TravelTime,
			StartTime:  route.StartTime,
			EndTime:    route.EndTime,
			Transfers:  route.Transfers,
		}
		for _, sec := range route.Sections {
			pbSec := convertSection(sec)
			pbRoute.Sections = append(pbRoute.Sections, pbSec)
			refs = append(refs, maasSectionRef{
				index: int32(len(refs)), source: sec, target: pbSec, route: pbRoute,
			})
			for _, alt := range sec.Alternatives {
				pbAlt := convertAlternative(alt)
				pbSec.Alternatives = append(pbSec.Alternatives, pbAlt)
				altRefs = append(altRefs, maasSectionRef{source: alt, target: pbAlt})
			}
		}
		out.Routes = append(out.Routes, pbRoute)
	}
	for i := range altRefs {
		altRefs[i].index = int32(len(refs) + i)
	}
	identityRefs := make([]maasSectionRef, 0, len(refs)+len(altRefs))
	identityRefs = append(identityRefs, refs...)
	identityRefs = append(identityRefs, altRefs...)
	batchBusNotificationIdentities(ctx, db, identityRefs)
	// No fare on an alternative: it is a departure the rider is being told
	// exists, not one the plan has priced.
	batchSectionFares(ctx, db, refs)
	return out, refs
}

func convertAlternative(sec tdxSection) *pb.Section {
	return &pb.Section{
		Type: sec.Type,
		Transport: &pb.Transport{
			Mode:       sec.Transport.Mode,
			Name:       sec.Transport.Name,
			ShortName:  sec.Transport.ShortName,
			LongName:   sec.Transport.LongName,
			Headsign:   sec.Transport.Headsign,
			Category:   sec.Transport.Category,
			RouteColor: sec.Transport.RouteColor,
		},
		Departure: &pb.Place{
			Name: sec.Departure.Place.Name,
			Type: sec.Departure.Place.Type,
			Time: sec.Departure.Time,
		},
		Arrival: &pb.Place{
			Name: sec.Arrival.Place.Name,
			Type: sec.Arrival.Place.Type,
			Time: sec.Arrival.Time,
		},
		NotificationIdentity: &pb.NotificationIdentity{},
	}
}

func enrichGeometry(ctx context.Context, db maasDB, osrmClient *resty.Client, refs []maasSectionRef) {
	enrichWalkSections(ctx, osrmClient, refs)
	enrichTransitPaths(ctx, db, refs)
}

func convertSection(sec tdxSection) *pb.Section {
	pbSec := &pb.Section{
		Type: sec.Type,
		TravelSummary: &pb.Summary{
			Duration: sec.TravelSummary.Duration,
			Length:   sec.TravelSummary.Length,
		},
		Departure: &pb.Place{
			Name: sec.Departure.Place.Name,
			Type: sec.Departure.Place.Type,
			Time: sec.Departure.Time,
			Location: &pb.Location{
				Lat: sec.Departure.Place.Location.Lat,
				Lng: sec.Departure.Place.Location.Lng,
			},
		},
		Arrival: &pb.Place{
			Name: sec.Arrival.Place.Name,
			Type: sec.Arrival.Place.Type,
			Time: sec.Arrival.Time,
			Location: &pb.Location{
				Lat: sec.Arrival.Place.Location.Lat,
				Lng: sec.Arrival.Place.Location.Lng,
			},
		},
		NotificationIdentity: &pb.NotificationIdentity{},
	}
	if sec.Transport.Mode != "" {
		pbSec.Transport = &pb.Transport{
			Mode:       sec.Transport.Mode,
			Name:       sec.Transport.Name,
			ShortName:  sec.Transport.ShortName,
			LongName:   sec.Transport.LongName,
			Headsign:   sec.Transport.Headsign,
			Category:   sec.Transport.Category,
			RouteColor: sec.Transport.RouteColor,
		}
	}
	for _, stop := range sec.IntermediateStops {
		pbSec.IntermediateStops = append(pbSec.IntermediateStops, &pb.IntermediateStop{
			Name:          stop.Departure.Place.Name,
			DepartureTime: stop.Departure.Time,
			Location: &pb.Location{
				Lat: stop.Departure.Place.Location.Lat,
				Lng: stop.Departure.Place.Location.Lng,
			},
		})
	}
	if sec.Agency.Name != "" {
		pbSec.Agency = &pb.Agency{
			AgencyId: sec.Agency.AgencyID,
			Name:     sec.Agency.Name,
			Website:  sec.Agency.Website,
			Phone:    sec.Agency.Phone,
		}
	}
	return pbSec
}

func batchBusNotificationIdentities(ctx context.Context, db maasDB, refs []maasSectionRef) {
	if db == nil {
		return
	}
	var indices []int32
	var departures, arrivals, names, shortNames, numbers []string
	byIndex := make(map[int32]*pb.Section)
	for _, ref := range refs {
		if !isBusMode(ref.source.Transport.Mode) {
			continue
		}
		indices = append(indices, ref.index)
		departures = append(departures, ref.source.Departure.Place.Name)
		arrivals = append(arrivals, ref.source.Arrival.Place.Name)
		names = append(names, ref.source.Transport.Name)
		shortNames = append(shortNames, ref.source.Transport.ShortName)
		numbers = append(numbers, ref.source.Transport.Number)
		byIndex[ref.index] = ref.target
	}
	if len(indices) == 0 {
		return
	}
	rows, err := db.Query(ctx, `
		WITH input AS (
			SELECT *
			FROM unnest($1::integer[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[])
				AS request(section_index, departure_name, arrival_name, route_name, sub_route_name, route_number)
		), matches AS (
			SELECT request.section_index, b.sub_route_uid, b.direction,
				departure.stop_uid AS departure_stop_uid,
				arrival.stop_uid AS arrival_stop_uid,
				COUNT(*) OVER (PARTITION BY request.section_index) AS match_count,
				ROW_NUMBER() OVER (
					PARTITION BY request.section_index
					ORDER BY b.sub_route_uid, b.direction, departure.stop_uid, arrival.stop_uid
				) AS match_rank
			FROM input request
			JOIN bus_subroutes b ON true
			JOIN bus_station_stop_map departure
			  ON departure.sub_route_uid = b.sub_route_uid AND departure.direction = b.direction
			JOIN bus_station_stop_map arrival
			  ON arrival.sub_route_uid = b.sub_route_uid AND arrival.direction = b.direction
			WHERE departure.station_name = request.departure_name
			  AND arrival.station_name = request.arrival_name
			  AND arrival.stop_sequence > departure.stop_sequence
			  AND (
				(request.route_name <> '' AND (b.route_name = request.route_name OR b.sub_route_name = request.route_name))
				OR (request.sub_route_name <> '' AND (b.route_name = request.sub_route_name OR b.sub_route_name = request.sub_route_name))
				OR (request.route_number <> '' AND (b.route_name = request.route_number OR b.sub_route_name = request.route_number))
			  )
		)
		SELECT section_index, sub_route_uid, direction, departure_stop_uid, arrival_stop_uid, match_count
		FROM matches
		WHERE match_rank = 1`, indices, departures, arrivals, names, shortNames, numbers)
	if err != nil {
		zap.S().Errorw("query error",
			"component", "maas",
			"action", "batch_notification_identity",
			"event", "query_error",
			"err", err,
		)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var index, direction int32
		var routeKey, departureStopKey, arrivalStopKey string
		var matchCount int64
		if err := rows.Scan(&index, &routeKey, &direction, &departureStopKey, &arrivalStopKey, &matchCount); err != nil {
			zap.S().Errorw("scan error",
				"component", "maas",
				"action", "batch_notification_identity",
				"event", "scan_error",
				"err", err,
			)
			return
		}
		if target := byIndex[index]; target != nil && matchCount == 1 {
			target.NotificationIdentity = &pb.NotificationIdentity{
				RouteType: "bus", RouteKey: routeKey, Direction: fmt.Sprint(direction),
				DepartureStopKey: departureStopKey, ArrivalStopKey: arrivalStopKey, Supported: true,
			}
		}
	}
	// A mid-stream failure leaves sections without an identity; enrichment is
	// best-effort and has no error channel, so surface it in the log instead.
	if err := rows.Err(); err != nil {
		zap.S().Errorw("iterate error",
			"component", "maas",
			"action", "batch_notification_identity",
			"event", "iterate_error",
			"err", err,
		)
	}
}

func batchSectionFares(ctx context.Context, db maasDB, refs []maasSectionRef) {
	if db == nil {
		return
	}
	var indices []int32
	var modes, departures, arrivals []string
	byIndex := make(map[int32]maasSectionRef)
	for _, ref := range refs {
		mode := ref.source.Transport.Mode
		if !isMetroMode(mode) && !isRailMode(mode) && !isThsrMode(mode) {
			continue
		}
		indices = append(indices, ref.index)
		modes = append(modes, strings.ToLower(mode))
		departures = append(departures, ref.source.Departure.Place.Name)
		arrivals = append(arrivals, ref.source.Arrival.Place.Name)
		byIndex[ref.index] = ref
	}
	if len(indices) == 0 {
		return
	}
	rows, err := db.Query(ctx, `
		WITH input AS (
			SELECT *
			FROM unnest($1::integer[], $2::text[], $3::text[], $4::text[])
				AS request(section_index, mode, departure_name, arrival_name)
		), fare_matches AS (
			SELECT request.section_index, m.fare_nt AS fare
			FROM input request
			JOIN mrt_station origin ON origin.name = request.departure_name
			JOIN mrt_station destination ON destination.name = request.arrival_name AND destination.system = origin.system
			JOIN mrt_journey_matrix m ON m.from_station_id = origin.station_id
				AND m.to_station_id = destination.station_id AND m.system = origin.system
			WHERE request.mode IN ('subway', 'metro', 'mrt')
			UNION ALL
			SELECT request.section_index, f.price
			FROM input request
			JOIN thsr_stations origin ON origin.name = request.departure_name
			JOIN thsr_stations destination ON destination.name = request.arrival_name
			JOIN thsr_fares f ON f.origin_station_id = origin.station_id AND f.destination_station_id = destination.station_id
			WHERE request.mode IN ('thsr', 'hsr') AND f.ticket_type = 1 AND f.fare_class = 1
			UNION ALL
			SELECT request.section_index, f.price
			FROM input request
			JOIN tra_stations origin ON origin.name = request.departure_name
			JOIN tra_stations destination ON destination.name = request.arrival_name
			JOIN tra_fares f ON f.origin_station_id = origin.station_id AND f.destination_station_id = destination.station_id
			WHERE request.mode IN ('rail', 'tra', 'train') AND f.ticket_type = '成復'
		)
		SELECT section_index, MIN(fare)::integer AS fare
		FROM fare_matches
		WHERE fare > 0
		GROUP BY section_index`, indices, modes, departures, arrivals)
	if err != nil {
		zap.S().Errorw("query error",
			"component", "maas",
			"action", "batch_section_fares",
			"event", "query_error",
			"err", err,
		)
		return
	}
	defer rows.Close()
	fares := make(map[int32]int32, len(byIndex))
	for rows.Next() {
		var index, fare int32
		if err := rows.Scan(&index, &fare); err != nil {
			zap.S().Errorw("scan error",
				"component", "maas",
				"action", "batch_section_fares",
				"event", "scan_error",
				"err", err,
			)
			return
		}
		if _, ok := byIndex[index]; !ok || fare <= 0 {
			continue
		}
		if current, ok := fares[index]; !ok || fare < current {
			fares[index] = fare
		}
	}
	// A mid-stream failure leaves fares partial, and applying it would understate
	// TotalFare rather than leave it unset. Drop the batch, like the scan path.
	if err := rows.Err(); err != nil {
		zap.S().Errorw("iterate error",
			"component", "maas",
			"action", "batch_section_fares",
			"event", "iterate_error",
			"err", err,
		)
		return
	}
	for index, fare := range fares {
		ref := byIndex[index]
		ref.target.Fare = fare
		ref.route.TotalFare += fare
	}
}

// clampInt returns v bounded to [lo,hi], or def when v is unset (0) and 0 is
// outside the valid range — so old clients / cached zero-value requests fall
// back to the TDX defaults rather than sending 0.
func clampInt(v, lo, hi, def int32) int32 {
	if v == 0 && (0 < lo || 0 > hi) {
		return def
	}
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func maasKey(req *pb.MaasPlanRequest) string {
	key := fmt.Sprintf("%.6f,%.6f,%.6f,%.6f,%s,%s,%v,%.2f,%v,%d,%d,%d,%d,%d,%d,%d",
		req.FromLat, req.FromLon, req.ToLat, req.ToLon,
		req.Date, req.Time, req.ArriveBy, req.Gc, req.TransitModes,
		req.Top, req.TransferTimeMin, req.TransferTimeMax,
		req.FirstMileMode, req.FirstMileTime, req.LastMileMode, req.LastMileTime)
	sum := sha256.Sum256([]byte(key))
	// v4: Section now carries transitPath (rail-shape-clipped geometry, see
	// enrichTransitPaths); bumped so a v3-cached response missing the new
	// field is never served after this deploy.
	return fmt.Sprintf("maas:plan:v4:%x", sum[:8])
}
