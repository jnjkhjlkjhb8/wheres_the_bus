package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/go-resty/resty/v2"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func TestLandTaoyuanTurnaroundsIsBestEffort(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusBadGateway)
	}))
	t.Cleanup(srv.Close)
	client := resty.New().SetBaseURL(srv.URL)

	t.Setenv("TDX_CLIENT_ID", "")
	landTaoyuanTurnarounds(context.Background(), client)
	if hits.Load() != 0 {
		t.Fatal("fetched TaoyuanRoute without TDX credentials")
	}

	core, observed := observer.New(zap.WarnLevel)
	t.Cleanup(zap.ReplaceGlobals(zap.New(core)))
	t.Setenv("TDX_CLIENT_ID", "test-id")
	t.Setenv("TDX_CLIENT_SECRET", "test-secret")
	landTaoyuanTurnarounds(context.Background(), client)
	if hits.Load() != 1 || observed.Len() != 1 {
		t.Fatalf("fetches = %d, warnings = %d; want one attempt whose failure is only logged", hits.Load(), observed.Len())
	}
}
