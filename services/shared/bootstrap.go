package shared

import (
	"context"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

func ConnectRedis() *redis.Client {
	client := redis.NewClient(&redis.Options{
		Addr:         os.Getenv("REDIS_ADDR"),
		Password:     os.Getenv("REDIS_PASSWORD"),
		DB:           0,
		PoolSize:     20,
		MinIdleConns: 3,
		PoolTimeout:  5 * time.Second,

		// v9 retries three times when MaxRetries is zero, where v6 did not retry
		// at all; -1 keeps the no-retry behavior the callers were written against.
		MaxRetries: -1,
		// Pin RESP2. v9 negotiates RESP3 by default, which changes reply shapes
		// for some commands; the wire protocol is not what this migration is
		// changing.
		Protocol: 2,
		// Without this, v9 applies only the socket timeouts and ignores context
		// deadlines — the whole point of moving off v6.
		ContextTimeoutEnabled: true,
		// Skip the CLIENT SETINFO handshake v9 sends on every new connection.
		DisableIdentity: true,
	})
	ctx := context.Background()
	var err error
	for i := 0; ; i++ {
		var pong string
		pong, err = client.Ping(ctx).Result()
		if err == nil {
			zap.S().Infow("connect success", "component", "redis", "action", "connect", "event", "success", "pong", pong)
			return client
		}
		if i >= 9 {
			zap.S().Errorw("connect failed", "component", "redis", "action", "connect", "event", "failed", "err", err)
			panic(err)
		}
		time.Sleep(time.Second)
	}
}

func ConnectDB(maxConnsEnv string, maxConnsDefault int32) *pgxpool.Pool {
	config, err := pgxpool.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		zap.S().Errorw("parse config failed", "component", "db", "action", "parse_config", "event", "failed", "err", err)
		panic(err)
	}
	if s := os.Getenv("PG_SCHEMA"); s != "" {
		config.ConnConfig.RuntimeParams["search_path"] = s
	}
	if t := os.Getenv("PG_STATEMENT_TIMEOUT"); t != "" {
		config.ConnConfig.RuntimeParams["statement_timeout"] = t
	}
	config.MaxConns = EnvInt32(maxConnsEnv, maxConnsDefault)
	config.MinConns = EnvInt32(strings.Replace(maxConnsEnv, "_MAX_", "_MIN_", 1), 2)
	config.MaxConnLifetime = 30 * time.Minute
	config.MaxConnIdleTime = 5 * time.Minute
	conn, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		zap.S().Errorw("connect failed", "component", "db", "action", "connect", "event", "failed", "err", err)
		panic(err)
	}
	if err = conn.Ping(context.Background()); err != nil {
		zap.S().Errorw("ping failed", "component", "db", "action", "ping", "event", "failed", "err", err)
		panic(err)
	}
	zap.S().Infow("connect success", "component", "db", "action", "connect", "event", "success")
	return conn
}

// EnvInt32 reads env var name as an int32, returning fallback when the var is
// unset, unparseable, or negative. Invalid non-empty values are logged before
// falling back.
func EnvInt32(name string, fallback int32) int32 {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	n, err := strconv.ParseInt(value, 10, 32)
	if err != nil || n < 0 {
		zap.S().Warnw("invalid", "component", "config", "name", name, "event", "invalid", "value", value, "fallback", fallback)
		return fallback
	}
	return int32(n)
}
