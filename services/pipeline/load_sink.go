package main

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/bus"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/mrt"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/rail"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/redis/go-redis/v9"
)

type loadSink interface {
	CopyUpsert(ctx context.Context, spec pipeline.CopyUpsertSpec, rows [][]any) error
	loadBusCity(ctx context.Context, src pipeline.LoadSource, city string) error
	loadBusDailyTimetable(ctx context.Context, dec *json.Decoder, src pipeline.LoadSource, city string) error
	loadMrtJourneyMatrix(ctx context.Context, dec *json.Decoder, system string) error
	loadMrtTravelTime(ctx context.Context, src pipeline.LoadSource, system string) error
	loadThsrStations(ctx context.Context, dec *json.Decoder, part string) error
}

// pgLoadSink is the production loadSink backed by the env-schema pool and Redis.
type pgLoadSink struct {
	db *pgxpool.Pool
	rc *redis.Client
}

func (s pgLoadSink) BeginLoadTx(ctx context.Context) (pipeline.LoadTx, error) {
	if s.db == nil {
		return nil, errors.New("nil PostgreSQL pool")
	}
	return s.db.Begin(ctx)
}

func (s pgLoadSink) loadBusCity(ctx context.Context, src pipeline.LoadSource, city string) error {
	return bus.Load(ctx, src, s.db, s.rc, city)
}

func (s pgLoadSink) loadBusDailyTimetable(ctx context.Context, dec *json.Decoder, src pipeline.LoadSource, city string) error {
	return bus.LoadDailyTimetable(ctx, dec, src, s.db, s.rc, city)
}

func (s pgLoadSink) loadMrtJourneyMatrix(ctx context.Context, dec *json.Decoder, system string) error {
	return mrt.LoadJourneyMatrix(ctx, dec, s, system)
}

func (s pgLoadSink) loadMrtTravelTime(ctx context.Context, src pipeline.LoadSource, system string) error {
	return mrt.LoadTrtcTravelTime(ctx, src, s, system)
}

func (s pgLoadSink) loadThsrStations(ctx context.Context, dec *json.Decoder, part string) error {
	return rail.LoadThsrStation(ctx, dec, s, part)
}

func (s pgLoadSink) CopyUpsert(ctx context.Context, spec pipeline.CopyUpsertSpec, rows [][]any) error {
	return pipeline.RunCopyUpsert(ctx, s, spec, rows)
}
