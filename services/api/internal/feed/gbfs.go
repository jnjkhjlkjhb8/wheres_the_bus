package feed

import (
	"context"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"golang.org/x/sync/singleflight"
	"google.golang.org/protobuf/proto"
)

const (
	_gbfsVersion     = "2.3"
	_gbfsSystemID    = "tw"
	_gbfsStaticTTL   = 3600
	_gbfsStatusTTL   = 30
	_gbfsStatusChunk = 1000
	// TDX ServiceStatus: 0 stopped, 1 in service, 2 suspended.
	_bikeServiceStopped   = 0
	_bikeServiceInService = 1
)

// gbfsWrite emits the envelope every GBFS file shares: when it was generated,
// how long it stays valid, the spec version, and the payload.
func gbfsWrite(c *gin.Context, ttl int, data any) {
	c.JSON(http.StatusOK, gin.H{
		"last_updated": time.Now().Unix(),
		"ttl":          ttl,
		"version":      _gbfsVersion,
		"data":         data,
	})
}

func handleGBFSDiscovery(serverPort string) gin.HandlerFunc {
	return func(c *gin.Context) {
		base := requestBaseURL(c.Request, serverPort)
		feeds := make([]gin.H, 0, len(_gbfsFeedNames))
		for _, name := range _gbfsFeedNames {
			feeds = append(feeds, gin.H{"name": name, "url": base + "/gbfs/" + name + ".json"})
		}
		// The spec keys feeds by language; this feed is published in one.
		gbfsWrite(c, _gbfsStaticTTL, gin.H{"zh-TW": gin.H{"feeds": feeds}})
	}
}

func requestBaseURL(r *http.Request, serverPort string) string {
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	host := r.Host
	if forwarded := r.Header.Get("X-Forwarded-Proto"); forwarded != "" {
		scheme = forwarded
	} else if _, _, err := net.SplitHostPort(host); err != nil {
		host = net.JoinHostPort(host, serverPort)
	}
	return scheme + "://" + host
}

func handleGBFSSystemInformation() gin.HandlerFunc {
	return func(c *gin.Context) {
		gbfsWrite(c, _gbfsStaticTTL, gin.H{
			"system_id": _gbfsSystemID,
			"language":  "zh-TW",
			"name":      "台灣公共自行車",
			"timezone":  "Asia/Taipei",
		})
	}
}

// gbfsStation is one row of station_information.
type gbfsStation struct {
	StationID string  `json:"station_id"`
	Name      string  `json:"name"`
	Lat       float64 `json:"lat"`
	Lon       float64 `json:"lon"`
	Address   string  `json:"address,omitempty"`
	Capacity  int32   `json:"capacity,omitempty"`
}

type gbfsStationSnapshot struct {
	stations  []gbfsStation
	expiresAt time.Time
}
type gbfsStatusSnapshot struct {
	statuses    []gbfsStatus
	expiresAt   time.Time
	generatedAt int64
}

type gbfsCache struct {
	sync.Mutex
	station gbfsStationSnapshot
	status  gbfsStatusSnapshot
	flight  singleflight.Group
}

func sharedGBFSStations(ctx context.Context, db *pgxpool.Pool, cache *gbfsCache) ([]gbfsStation, error) {
	now := time.Now()
	cache.Lock()
	snapshot := cache.station
	cache.Unlock()
	if now.Before(snapshot.expiresAt) {
		return snapshot.stations, nil
	}
	resultCh := cache.flight.DoChan("stations", func() (any, error) {
		buildCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cache.Lock()
		current := cache.station
		cache.Unlock()
		if time.Now().Before(current.expiresAt) {
			return current.stations, nil
		}
		stations, queryErr := gbfsStations(buildCtx, db)
		if queryErr != nil {
			return nil, queryErr
		}
		cache.Lock()
		cache.station = gbfsStationSnapshot{stations: stations, expiresAt: time.Now().Add(_gbfsStaticTTL * time.Second)}
		cache.Unlock()
		return stations, nil
	})
	select {
	case result := <-resultCh:
		if result.Err != nil {
			return nil, result.Err
		}
		return result.Val.([]gbfsStation), nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func gbfsStations(ctx context.Context, db *pgxpool.Pool) ([]gbfsStation, error) {
	rows, err := db.Query(ctx, `
		SELECT station_uid, name, ST_Y(geom), ST_X(geom), COALESCE(address, ''), COALESCE(capacity, 0)
		FROM bike_stations
		WHERE geom IS NOT NULL
		ORDER BY station_uid`)
	if err != nil {
		return nil, _oops.Wrapf(err, "gbfs stations: query")
	}
	defer rows.Close()
	stations := make([]gbfsStation, 0, 12000)
	for rows.Next() {
		var s gbfsStation
		if err := rows.Scan(&s.StationID, &s.Name, &s.Lat, &s.Lon, &s.Address, &s.Capacity); err != nil {
			return nil, _oops.Wrapf(err, "gbfs stations: scan")
		}
		stations = append(stations, s)
	}
	if err := rows.Err(); err != nil {
		return nil, _oops.Wrapf(err, "gbfs stations: rows")
	}
	return stations, nil
}

func handleGBFSStationInformation(db *pgxpool.Pool, cache *gbfsCache) gin.HandlerFunc {
	return func(c *gin.Context) {
		stations, err := sharedGBFSStations(c.Request.Context(), db, cache)
		if err != nil {
			zap.S().Errorw("failed",
				"component", "gbfs",
				"action", "station_information",
				"event", "failed",
				"err", err,
			)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "station information unavailable"})
			return
		}
		gbfsWrite(c, _gbfsStaticTTL, gin.H{"stations": stations})
	}
}

// gbfsStatus is one row of station_status.
type gbfsStatus struct {
	StationID         string `json:"station_id"`
	NumBikesAvailable int32  `json:"num_bikes_available"`
	NumDocksAvailable int32  `json:"num_docks_available"`
	IsInstalled       bool   `json:"is_installed"`
	IsRenting         bool   `json:"is_renting"`
	IsReturning       bool   `json:"is_returning"`
	LastReported      int64  `json:"last_reported"`
}

func handleGBFSStationStatus(db *pgxpool.Pool, rc *redis.Client, cache *gbfsCache) gin.HandlerFunc {
	return func(c *gin.Context) {
		ctx := c.Request.Context()
		cache.Lock()
		cached := cache.status
		cache.Unlock()
		if time.Now().Before(cached.expiresAt) {
			gbfsWrite(c, _gbfsStatusTTL, gin.H{"stations": cached.statuses})
			return
		}
		resultCh := cache.flight.DoChan("status", func() (any, error) {
			buildCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			cache.Lock()
			current := cache.status
			cache.Unlock()
			if time.Now().Before(current.expiresAt) {
				return current, nil
			}
			stations, stationsErr := sharedGBFSStations(buildCtx, db, cache)
			if stationsErr != nil {
				return nil, stationsErr
			}
			statuses, statusErr := buildGBFSStatuses(buildCtx, rc, stations)
			if statusErr != nil {
				return nil, statusErr
			}
			result := gbfsStatusSnapshot{statuses: statuses, expiresAt: time.Now().Add(_gbfsStatusTTL * time.Second), generatedAt: time.Now().Unix()}
			cache.Lock()
			cache.status = result
			cache.Unlock()
			return result, nil
		})
		var value any
		var err error
		select {
		case result := <-resultCh:
			if result.Err != nil {
				err = result.Err
			} else {
				value = result.Val
			}
		case <-ctx.Done():
			err = ctx.Err()
		}
		if err != nil {
			zap.S().Errorw("failed", "component", "gbfs", "action", "station_status", "event", "failed", "err", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "station status unavailable"})
			return
		}
		snapshot := value.(gbfsStatusSnapshot)
		gbfsWrite(c, _gbfsStatusTTL, gin.H{"stations": snapshot.statuses})
	}
}

func buildGBFSStatuses(ctx context.Context, rc *redis.Client, stations []gbfsStation) ([]gbfsStatus, error) {
	statuses := make([]gbfsStatus, 0, len(stations))
	for start := 0; start < len(stations); start += _gbfsStatusChunk {
		end := min(start+_gbfsStatusChunk, len(stations))
		chunk := stations[start:end]
		keys := make([]string, len(chunk))
		observedKeys := make([]string, len(chunk))
		for i, s := range chunk {
			keys[i] = shared.BikeAvailabilityKey(s.StationID)
			observedKeys[i] = shared.BikeAvailabilityObservedAtKey(s.StationID)
		}
		values, err := rc.MGet(ctx, keys...).Result()
		if err != nil {
			zap.S().Errorw("mget failed",
				"component", "gbfs",
				"action", "station_status",
				"event", "mget_failed",
				"err", err,
			)
			return nil, err
		}
		observedValues, err := rc.MGet(ctx, observedKeys...).Result()
		if err != nil {
			return nil, err
		}
		for i, value := range values {
			observedAt := int64(0)
			if raw, ok := observedValues[i].(string); ok {
				observedAt, _ = strconv.ParseInt(raw, 10, 64)
			}
			status, ok := decodeBikeStatus(chunk[i].StationID, value, observedAt)
			if !ok {
				continue
			}
			statuses = append(statuses, status)
		}
	}
	if len(statuses) < len(stations) {
		zap.S().Infow("partial",
			"component", "gbfs",
			"action", "station_status",
			"event", "partial",
			"stations", len(stations),
			"reported", len(statuses),
		)
	}
	return statuses, nil
}

// decodeBikeStatus turns one cached Bike_eta into a GBFS status row. It reports
// false for a missing key or an undecodable value, which the caller omits.
func decodeBikeStatus(stationID string, value any, now int64) (gbfsStatus, bool) {
	raw, ok := value.(string)
	if !ok || raw == "" {
		return gbfsStatus{}, false
	}
	var eta models.BikeEta
	if err := proto.Unmarshal([]byte(raw), &eta); err != nil {
		zap.S().Warnw("decode failed",
			"component", "gbfs",
			"action", "station_status",
			"station", stationID,
			"event", "decode_failed",
			"err", err,
		)
		return gbfsStatus{}, false
	}
	inService := eta.GetServiceStatus() == _bikeServiceInService
	return gbfsStatus{
		StationID:         stationID,
		NumBikesAvailable: eta.GetGeneralBikes() + eta.GetElectricBikes(),
		NumDocksAvailable: eta.GetAvailableReturnBikes(),
		IsInstalled:       eta.GetServiceStatus() != _bikeServiceStopped,
		IsRenting:         inService,
		IsReturning:       inService,
		LastReported:      now,
	}, true
}

// _gbfsFeedNames is the file set the discovery document advertises. It is also
// what registerGBFSRoutes mounts, so a file cannot be advertised without being
// served.
var _gbfsFeedNames = []string{"system_information", "station_information", "station_status"}

// RegisterGBFSRoutes mounts the feed. Every file is unauthenticated: the whole
// point is that a planner can poll it. The rate limit is the only guard, and it
// is shared across the files because they are polled together.
func RegisterGBFSRoutes(r gin.IRoutes, db *pgxpool.Pool, rc *redis.Client, limit gin.HandlerFunc, serverPort string) {
	cache := &gbfsCache{}
	handlers := map[string]gin.HandlerFunc{
		"system_information":  handleGBFSSystemInformation(),
		"station_information": handleGBFSStationInformation(db, cache),
		"station_status":      handleGBFSStationStatus(db, rc, cache),
	}
	r.GET("/gbfs/gbfs.json", limit, handleGBFSDiscovery(serverPort))
	for _, name := range _gbfsFeedNames {
		r.GET("/gbfs/"+name+".json", limit, handlers[name])
	}
}
