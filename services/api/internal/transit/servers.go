// Package transit serves the bus, bike-share, and nearby-station read paths:
// static data from PostgreSQL behind a TTL cache, live ETA and availability
// streamed out of Redis Pub/Sub.
package transit

import (
	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/cache"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/nearby"
	"github.com/redis/go-redis/v9"
)

// BusRouteserver serves per-route bus queries: static route data from
// PostgreSQL (memoized in cache) and live ETA streamed from Redis Pub/Sub.
type BusRouteserver struct {
	pb.UnimplementedBus_Route_ServiceServer

	db    *pgxpool.Pool
	rc    *redis.Client
	cache *cache.TTLCache
	live  livestream.LiveSource
}

// BusStationserver serves station-group bus queries: group membership from
// PostgreSQL and per-station live ETA streamed from Redis Pub/Sub.
type BusStationserver struct {
	pb.UnimplementedBus_Station_ServiceServer

	db   *pgxpool.Pool
	rc   *redis.Client
	live livestream.LiveSource
}

// BikeServer serves bike-share station static data from PostgreSQL (memoized in
// cache) and live availability streamed from Redis Pub/Sub.
type BikeServer struct {
	pb.UnimplementedBike_ServiceServer

	db    *pgxpool.Pool
	rc    *redis.Client
	cache *cache.TTLCache
	live  livestream.LiveSource
}

// NearServer streams results from the nearby discovery module.
type NearServer struct {
	pb.UnimplementedNear_Station_ServiceServer

	discovery *nearby.NearbyDiscovery
}

// NewBusRouteServer wires the per-route bus read path.
func NewBusRouteServer(db *pgxpool.Pool, rc *redis.Client, cache *cache.TTLCache, live livestream.LiveSource) *BusRouteserver {
	return &BusRouteserver{db: db, rc: rc, cache: cache, live: live}
}

// NewBusStationServer wires the station-group bus read path.
func NewBusStationServer(db *pgxpool.Pool, rc *redis.Client, live livestream.LiveSource) *BusStationserver {
	return &BusStationserver{db: db, rc: rc, live: live}
}

// NewBikeServer wires the bike-share read path.
func NewBikeServer(db *pgxpool.Pool, rc *redis.Client, cache *cache.TTLCache, live livestream.LiveSource) *BikeServer {
	return &BikeServer{db: db, rc: rc, cache: cache, live: live}
}

// NewNearServer wires the nearby discovery module behind its streaming RPC.
func NewNearServer(discovery *nearby.NearbyDiscovery) *NearServer {
	return &NearServer{discovery: discovery}
}
