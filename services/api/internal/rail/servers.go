package rail

import (
	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/redis/go-redis/v9"
)

type ThsrServer struct {
	pb.UnimplementedThsrTimetableServiceServer

	db   *pgxpool.Pool
	rc   *redis.Client
	live livestream.LiveSource
}

type TraTimetableServer struct {
	pb.UnimplementedTRATimetableServiceServer

	db   *pgxpool.Pool
	rc   *redis.Client
	live livestream.LiveSource
}

type TraDetainServer struct {
	pb.UnimplementedTRA_DetainServiceServer

	db   *pgxpool.Pool
	rc   *redis.Client
	live livestream.LiveSource
}

type ThsrDetainServer struct {
	pb.UnimplementedThsr_DetainServiceServer

	db   *pgxpool.Pool
	rc   *redis.Client
	live livestream.LiveSource
}

// NewThsrServer wires the read-only dependencies the server needs.
func NewThsrServer(db *pgxpool.Pool, rc *redis.Client, live livestream.LiveSource) *ThsrServer {
	return &ThsrServer{db: db, rc: rc, live: live}
}

// NewTraTimetableServer wires the read-only dependencies the server needs.
func NewTraTimetableServer(db *pgxpool.Pool, rc *redis.Client, live livestream.LiveSource) *TraTimetableServer {
	return &TraTimetableServer{db: db, rc: rc, live: live}
}

// NewTraDetainServer wires the read-only dependencies the server needs.
func NewTraDetainServer(db *pgxpool.Pool, rc *redis.Client, live livestream.LiveSource) *TraDetainServer {
	return &TraDetainServer{db: db, rc: rc, live: live}
}

// NewThsrDetainServer wires the read-only dependencies the server needs.
func NewThsrDetainServer(db *pgxpool.Pool, rc *redis.Client, live livestream.LiveSource) *ThsrDetainServer {
	return &ThsrDetainServer{db: db, rc: rc, live: live}
}
