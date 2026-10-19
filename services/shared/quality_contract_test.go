package shared

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestUIDCityLookupRequiresKnownThreeCharacterPrefix(t *testing.T) {
	for _, tc := range []struct{ uid, city string }{{"", ""}, {"TP", ""}, {"TPE", "Taipei"}, {"TPE1234", "Taipei"}, {"unknown", ""}} {
		if got := CityFromUID(tc.uid); got != tc.city {
			t.Fatalf("city %s=%s want %s", tc.uid, got, tc.city)
		}
	}
	if uid, direction := CanonicalSubroute("InterCity", "THB9023A3", 9); uid != "THB9023A3" || direction != 9 {
		t.Fatalf("invalid direction suffix=%s/%d", uid, direction)
	}
}

func TestGRPCClientCredentialsLoadOrReturnCertificateFailure(t *testing.T) {
	dir := newTestCA(t).leafDir(t, "rider-api")
	creds, err := GRPCClientCreds(dir, "rider-api")
	if err != nil || creds.Info().SecurityProtocol != "tls" {
		t.Fatalf("credentials=%v error=%v", creds, err)
	}
	if _, err := GRPCClientCreds(t.TempDir(), "rider-api"); err == nil {
		t.Fatal("missing certificate accepted")
	}
}

func TestRedisTDXStoreMissingValueWriteReadDelete(t *testing.T) {
	addr := envOrSkip(t, "REDIS_TEST_ADDR")
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 11})
	key := "quality:tdx:" + t.Name()
	t.Cleanup(func() { rc.Del(context.Background(), key); _ = rc.Close() })
	store := RedisTDXStore{RC: rc}
	if v, err := store.Get(t.Context(), key); v != "" || err != nil {
		t.Fatalf("missing=%s/%v", v, err)
	}
	if err := store.Set(t.Context(), key, "value", time.Minute); err != nil {
		t.Fatal(err)
	}
	if v, err := store.Get(t.Context(), key); v != "value" || err != nil {
		t.Fatalf("stored=%s/%v", v, err)
	}
	if err := store.Del(t.Context(), key); err != nil {
		t.Fatal(err)
	}
	_ = rc.Close()
	if _, err := store.Get(t.Context(), key); err == nil {
		t.Fatal("closed Redis error lost")
	}
}

type captureTap struct {
	bytes.Buffer
	closed bool
}

func (t *captureTap) Close() error { t.closed = true; return nil }

func TestTDXTapRecordsUnreadTailAndCloses(t *testing.T) {
	for _, tap := range []TDXTap{nil, func(string) io.WriteCloser { return nil }} {
		body := io.NopCloser(bytes.NewBufferString("body"))
		if got := tappedBody(body, tap, "dataset"); got != body {
			t.Fatal("absent sink changed body")
		}
	}
	capture := &captureTap{}
	body := tappedBody(io.NopCloser(bytes.NewBufferString("whole body")), func(name string) io.WriteCloser {
		if name != "dataset" {
			t.Fatalf("tap name=%s", name)
		}
		return capture
	}, "dataset")
	first := make([]byte, 2)
	if _, err := io.ReadFull(body, first); err != nil {
		t.Fatal(err)
	}
	if err := body.Close(); err != nil {
		t.Fatal(err)
	}
	if capture.String() != "whole body" || !capture.closed {
		t.Fatalf("archive=%q closed=%v", capture.String(), capture.closed)
	}
}

func TestAuthedTDXClientAttachesTokenAndRejectsCacheFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer cached" {
			t.Errorf("authorization=%s", r.Header.Get("Authorization"))
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	store := newMemTDXStore()
	store.data[TDXTokenKey] = "cached"
	client := NewTDXClient(TDXConfig{Store: store})
	if _, err := client.NewAuthedClient(server.URL).R().Get("/x"); err != nil {
		t.Fatal(err)
	}
	store.getErr = map[string]error{TDXTokenKey: errors.New("cache unavailable")}
	if _, err := client.NewAuthedClient(server.URL).R().Get("/x"); !IsTDXAuthError(err) {
		t.Fatalf("auth failure=%v", err)
	}
}

func TestTDXResponseSpoolFailureLeavesMarkerUnchanged(t *testing.T) {
	want := errors.New("response close failed")
	client := NewTDXClient(TDXConfig{Store: newMemTDXStore(), IMSKey: func(s string) string { return s }})
	called := false
	if err := client.commitResponseBody(t.Context(), "dataset", "new", failingCloseBody{bytes.NewBufferString("data"), want}, func(TDXIntoCommit) error { called = true; return nil }); !errors.Is(err, want) || called {
		t.Fatalf("prepare failure=%v callback=%v", err, called)
	}
	if err := client.commitResponseBody(t.Context(), "dataset", "new", io.NopCloser(bytes.NewBufferString("data")), func(commit TDXIntoCommit) error { return commit.Body.(*os.File).Close() }); err == nil {
		t.Fatal("closed spool committed marker")
	}
	if marker, err := client.store.Get(t.Context(), "dataset"); marker != "" || err != nil {
		t.Fatalf("failed commit marker=%s error=%v", marker, err)
	}
}

func TestTDXRejectsUnsupportedAndMalformedContentEncodings(t *testing.T) {
	for _, encoding := range []string{"br", "gzip"} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Encoding", encoding)
			w.Header().Set("Last-Modified", "marker")
			_, _ = io.WriteString(w, "invalid")
		}))
		store := newMemTDXStore()
		store.data[TDXTokenKey] = "cached"
		client := NewTDXClient(TDXConfig{Store: store, BaseURL: server.URL, IMSKey: func(s string) string { return s }})
		if fetch, err := client.Get(t.Context(), "/x", "dataset"); fetch != nil || err == nil {
			t.Fatalf("encoding %s accepted: %v/%v", encoding, fetch, err)
		}
		server.Close()
	}
}
