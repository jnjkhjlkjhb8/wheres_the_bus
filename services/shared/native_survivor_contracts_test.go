package shared

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func sharedContractResponse(request *http.Request, status int, marker, body string) *http.Response {
	header := make(http.Header)
	header.Set("Last-Modified", marker)
	return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(body)), Request: request}
}

func sharedContractTDXClient(t *testing.T) (*TDXClient, *memTDXStore) {
	t.Helper()
	store := newMemTDXStore()
	store.data[TDXTokenKey] = "owned-cached-token"
	client := NewTDXClient(TDXConfig{Store: store, IMSKey: TDXRawIMSKey, BaseURL: "https://quality.invalid"})
	return client, store
}

func sharedContractOwnFetch(t *testing.T, fetch *TDXFetch) func() error {
	t.Helper()
	closed := false
	closeOwned := func() error {
		if fetch == nil || closed {
			return nil
		}
		closed = true
		return fetch.Close()
	}
	t.Cleanup(func() {
		if err := closeOwned(); err != nil {
			t.Error(err)
		}
	})
	return closeOwned
}

func TestPublicRedisConnectionKeepsNoRetryAndFiveSecondPoolWaitPolicy(t *testing.T) {
	t.Setenv("REDIS_ADDR", envOrSkip(t, "REDIS_TEST_ADDR"))
	t.Setenv("REDIS_PASSWORD", "")
	client := ConnectRedis()
	t.Cleanup(func() { _ = client.Close() })
	options := client.Options()
	if options.MaxRetries != 0 || options.PoolTimeout != 5*time.Second {
		t.Fatalf("public connection retry/pool policy maxRetries=%d poolTimeout=%v", options.MaxRetries, options.PoolTimeout)
	}
}

func TestPublicDatabaseConnectionUsesRequestedPrivateSchema(t *testing.T) {
	if os.Getenv("DATABASE_URL") == "" {
		t.Skip("DATABASE_URL required")
	}
	t.Setenv("QUALITY_SHARED_MAX_CONNS", "2")
	t.Setenv("QUALITY_SHARED_MIN_CONNS", "0")
	t.Setenv("PG_SCHEMA", "")
	admin := ConnectDB("QUALITY_SHARED_MAX_CONNS", 2)
	schema := fmt.Sprintf("quality_shared_%d_%d", os.Getpid(), time.Now().UnixNano())
	identifier := pgx.Identifier{schema}.Sanitize()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if _, err := admin.Exec(ctx, "CREATE SCHEMA "+identifier); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if _, err := admin.Exec(cleanup, "DROP SCHEMA "+identifier+" CASCADE"); err != nil {
			t.Error(err)
		}
		admin.Close()
	})
	t.Setenv("PG_SCHEMA", schema)
	pool := ConnectDB("QUALITY_SHARED_MAX_CONNS", 2)
	t.Cleanup(pool.Close)
	var actual string
	if err := pool.QueryRow(ctx, "SELECT current_schema()").Scan(&actual); err != nil || actual != schema {
		t.Fatalf("private schema=%q want=%q err=%v", actual, schema, err)
	}
}

func TestCanonicalIntercitySubrouteIncludesShortestAndLastBranchMarkers(t *testing.T) {
	for _, tc := range []struct {
		input, want string
		direction   uint8
	}{{"01", "", 0}, {"02", "", 1}, {"Z1", "Z", 0}, {"Z2", "Z", 1}, {"THB9023Z2", "THB9023Z", 1}} {
		uid, direction := CanonicalSubroute("InterCity", tc.input, 9)
		if uid != tc.want || direction != tc.direction {
			t.Fatalf("subroute %q=%q/%d want=%q/%d", tc.input, uid, direction, tc.want, tc.direction)
		}
	}
}

type sharedContractTokenStore struct {
	*memTDXStore
	tokenTTL time.Duration
}

func (s *sharedContractTokenStore) Set(ctx context.Context, key, value string, ttl time.Duration) error {
	if key == TDXTokenKey {
		s.tokenTTL = ttl
	}
	return s.memTDXStore.Set(ctx, key, value, ttl)
}

func TestPublicTokenExchangeHasThirtySecondTransportBudgetAndSixHourCacheLease(t *testing.T) {
	store := &sharedContractTokenStore{memTDXStore: newMemTDXStore()}
	client := NewTDXClient(TDXConfig{Store: store})
	var deadline time.Time
	var bounded bool
	client.tokenHTTP.Transport = tdxRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		deadline, bounded = request.Context().Deadline()
		return sharedContractResponse(request, http.StatusOK, "", `{"access_token":"owned-token"}`), nil
	})
	before := time.Now()
	token, err := client.Token(context.Background())
	after := time.Now()
	if err != nil || token != "owned-token" || store.get(TDXTokenKey) != token || store.tokenTTL != 6*time.Hour {
		t.Fatalf("token=%q cached=%q lease=%v err=%v", token, store.get(TDXTokenKey), store.tokenTTL, err)
	}
	if !bounded || deadline.Before(before.Add(30*time.Second)) || deadline.After(after.Add(30*time.Second)) {
		t.Fatalf("token transport deadline=%v bounded=%v window=[%v,%v]", deadline, bounded, before, after)
	}
}

func TestPublicTDXFetchTransportsHaveThirtySecondRequestBudgets(t *testing.T) {
	for _, authed := range []bool{false, true} {
		t.Run(fmt.Sprint(authed), func(t *testing.T) {
			client, _ := sharedContractTDXClient(t)
			var deadline time.Time
			var bounded bool
			transport := tdxRoundTripFunc(func(request *http.Request) (*http.Response, error) {
				deadline, bounded = request.Context().Deadline()
				return sharedContractResponse(request, http.StatusOK, "owned-marker", `[]`), nil
			})
			before := time.Now()
			if authed {
				httpClient := client.NewAuthedClient("https://quality.invalid")
				httpClient.SetTransport(transport)
				if _, err := httpClient.R().SetContext(context.Background()).Get("/owned"); err != nil {
					t.Fatal(err)
				}
			} else {
				client.http.SetTransport(transport)
				fetch, err := client.Get(context.Background(), "/owned", "owned-dataset")
				closeOwned := sharedContractOwnFetch(t, fetch)
				if err != nil {
					t.Fatal(err)
				}
				if err := closeOwned(); err != nil {
					t.Fatal(err)
				}
			}
			after := time.Now()
			if !bounded || deadline.Before(before.Add(30*time.Second)) || deadline.After(after.Add(30*time.Second)) {
				t.Fatalf("fetch deadline=%v bounded=%v window=[%v,%v]", deadline, bounded, before, after)
			}
		})
	}
}

func TestPublicTDXRejectsHTTP400DespiteOtherwiseValidTokenOrFeedBodies(t *testing.T) {
	store := newMemTDXStore()
	client := NewTDXClient(TDXConfig{Store: store})
	client.tokenHTTP.Transport = tdxRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		return sharedContractResponse(request, http.StatusBadRequest, "", `{"access_token":"must-not-cache"}`), nil
	})
	if token, err := client.Token(context.Background()); token != "" || err == nil || store.get(TDXTokenKey) != "" {
		t.Fatalf("HTTP400 token=%q cached=%q err=%v", token, store.get(TDXTokenKey), err)
	}
	client, store = sharedContractTDXClient(t)
	client.http.SetTransport(tdxRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		return sharedContractResponse(request, http.StatusBadRequest, "must-not-cache", `[]`), nil
	}))
	fetch, err := client.Get(context.Background(), "/owned", "owned-dataset")
	sharedContractOwnFetch(t, fetch)
	var status *TDXStatusError
	if fetch != nil || !errors.As(err, &status) || status.Status != http.StatusBadRequest || store.get(TDXRawIMSKey("owned-dataset")) != "" {
		t.Fatalf("HTTP400 fetch=%v status=%v err=%v", fetch, status, err)
	}
}

func TestPublicTDXWarmRawMarkerSkipsDatabaseFallback(t *testing.T) {
	client, store := sharedContractTDXClient(t)
	const name = "owned-dataset"
	const key = "shared:raw:last_modified:owned-dataset"
	store.data[key] = "owned-cached-marker"
	fallbackCalled := false
	client.sinceFallback = func(string) string { fallbackCalled = true; return "fallback-marker" }
	var actual string
	client.http.SetTransport(tdxRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		actual = request.Header.Get("If-Modified-Since")
		return sharedContractResponse(request, http.StatusNotModified, "", ""), nil
	}))
	fetch, err := client.Get(context.Background(), "/owned", name)
	closeOwned := sharedContractOwnFetch(t, fetch)
	if err != nil || fetch == nil || fetch.Modified || actual != "owned-cached-marker" || fallbackCalled || TDXRawIMSKey(name) != key {
		t.Fatalf("warm marker=%q fallback=%v fetch=%v err=%v", actual, fallbackCalled, fetch, err)
	}
	if err := closeOwned(); err != nil {
		t.Fatal(err)
	}
}

func TestPublicTDXRetryExhaustionKeepsSixRequestsAndFiveSecondBackoff(t *testing.T) {
	client, _ := sharedContractTDXClient(t)
	var attempts []time.Time
	client.http.SetTransport(tdxRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		attempts = append(attempts, time.Now())
		if len(attempts) > 6 {
			return nil, &TDXAuthError{Err: errors.New("quality request limit exceeded")}
		}
		return sharedContractResponse(request, http.StatusTooManyRequests, "", `[]`), nil
	}))
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	fetch, err := client.Get(ctx, "/owned", "owned-dataset")
	sharedContractOwnFetch(t, fetch)
	var status *TDXStatusError
	if fetch != nil || !errors.As(err, &status) || status.Status != http.StatusTooManyRequests || len(attempts) != 6 {
		t.Fatalf("exhausted retry fetch=%v attempts=%d err=%v", fetch, len(attempts), err)
	}
	for i, minimum := range []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 5 * time.Second, 5 * time.Second} {
		if elapsed := attempts[i+1].Sub(attempts[i]); elapsed < minimum {
			t.Fatalf("retry %d interval=%v below public backoff=%v", i+1, elapsed, minimum)
		}
	}
}

type sharedContractDeleteFailureStore struct {
	*memTDXStore
	cause error
}

func (s *sharedContractDeleteFailureStore) Del(context.Context, ...string) error { return s.cause }

func TestPublicTDXMarkerInvalidationPreservesOriginalStorageCause(t *testing.T) {
	for _, modified := range []bool{false, true} {
		client, memory := sharedContractTDXClient(t)
		cause := errors.New("quality marker delete unavailable")
		client.store = &sharedContractDeleteFailureStore{memTDXStore: memory, cause: cause}
		memory.data[TDXRawIMSKey("owned-dataset")] = "owned-old-marker"
		client.http.SetTransport(tdxRoundTripFunc(func(request *http.Request) (*http.Response, error) {
			status := http.StatusNotModified
			if modified {
				status = http.StatusOK
			}
			return sharedContractResponse(request, status, "owned-new-marker", `[]`), nil
		}))
		fetch, err := client.Get(context.Background(), "/owned", "owned-dataset")
		closeOwned := sharedContractOwnFetch(t, fetch)
		if err != nil {
			t.Fatal(err)
		}
		if err := fetch.Invalidate(); !errors.Is(err, cause) || memory.get(TDXRawIMSKey("owned-dataset")) != "owned-old-marker" {
			t.Fatalf("invalidation err=%v retained=%q", err, memory.get(TDXRawIMSKey("owned-dataset")))
		}
		if err := closeOwned(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestPublicTDXCommittedResponseKeepsMarkerWriteFailureCause(t *testing.T) {
	client, store := sharedContractTDXClient(t)
	key := TDXRawIMSKey("owned-dataset")
	store.data[key] = "owned-old-marker"
	cause := errors.New("quality marker write unavailable")
	store.setErr = cause
	client.http.SetTransport(tdxRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		return sharedContractResponse(request, http.StatusOK, "owned-new-marker", `[{"id":1}]`), nil
	}))
	committed := false
	_, err := client.GetInto(context.Background(), "/owned", "owned-dataset", func(commit TDXIntoCommit) error {
		payload, err := io.ReadAll(commit.Body)
		if err != nil {
			return err
		}
		if string(payload) != `[{"id":1}]` || commit.Marker != "owned-new-marker" {
			return errors.New("quality commit body/marker mismatch")
		}
		committed = true
		return nil
	})
	if !committed || !errors.Is(err, cause) || store.get(key) != "owned-old-marker" {
		t.Fatalf("commit=%v retained=%q err=%v", committed, store.get(key), err)
	}
}

func TestPublicTRTCTrainInfoRequestHasFifteenSecondTransportBudget(t *testing.T) {
	client := NewTRTCTrainInfoClient("owned-user", "owned-password")
	var deadline time.Time
	var bounded bool
	client.http.SetTransport(tdxRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		deadline, bounded = request.Context().Deadline()
		return sharedContractResponse(request, http.StatusOK, "", `{"TripId":"owned-trip","StnName":"owned-station"}`), nil
	}))
	before := time.Now()
	info, found, err := client.GetTrainInfo(context.Background(), "owned-car")
	after := time.Now()
	if err != nil || !found || info == nil || info.TripID != "owned-trip" || !bounded || deadline.Before(before.Add(15*time.Second)) || deadline.After(after.Add(15*time.Second)) {
		t.Fatalf("train=%+v found=%v deadline=%v bounded=%v err=%v", info, found, deadline, bounded, err)
	}
}
