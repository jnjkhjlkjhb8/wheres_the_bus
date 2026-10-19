package main

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPGStaticPipelineAcquireConnectionFailureRetainsCause(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	config, err := pgxpool.ParseConfig("postgres://test:test@127.0.0.1:1/test")
	if err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	cause := errors.New("dedicated advisory connection unavailable")
	var calls int
	var receivedContext context.Context
	var receivedDatabase string
	locker := pgStaticPipelineLocker{connector: pgStaticPipelineConnector{
		pool: pool,
		connect: func(callContext context.Context, copied *pgx.ConnConfig) (staticPipelineDedicatedConn, error) {
			calls++
			receivedContext = callContext
			receivedDatabase = copied.Database
			return nil, cause
		},
	}}
	release, err := locker.Acquire(ctx)
	if !errors.Is(err, cause) {
		t.Fatalf("Acquire error = %v, want original connection cause %v", err, cause)
	}
	if release != nil {
		t.Fatal("failed advisory connection returned a release callback")
	}
	if calls != 1 || receivedContext != ctx || receivedDatabase != "test" {
		t.Fatalf("connection request = %d calls, caller context %t, database %q", calls, receivedContext == ctx, receivedDatabase)
	}
	if got := pool.Stat().AcquiredConns(); got != 0 {
		t.Fatalf("failed dedicated connection consumed %d pooled connections", got)
	}
}
