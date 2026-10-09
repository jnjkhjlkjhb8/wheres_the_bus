package metrotrack

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

type fakeTrackCancelStore struct {
	cancelled []string
	pending   map[string]bool
	err       error
}

func (f *fakeTrackCancelStore) CancelArrivalReminderByID(_ context.Context, reminderID string) (bool, error) {
	if f.err != nil {
		return false, f.err
	}
	f.cancelled = append(f.cancelled, reminderID)
	return f.pending[reminderID], nil
}

// unreachableRedis stands in for "the publish will not land", which every
// assertion here is indifferent to: the cancel is the database write, and a
// watcher that misses the ending still sees the session stop advancing.
func unreachableRedis(t *testing.T) *redis.Client {
	t.Helper()
	return redis.NewClient(&redis.Options{
		Addr:        "127.0.0.1:1",
		DialTimeout: 50 * time.Millisecond,
		ReadTimeout: 50 * time.Millisecond,
		MaxRetries:  0,
	})
}

func postTrackCancel(t *testing.T, store trackCancelStore, body string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	engine.POST(TrackCancelPath, HandleTrackCancel(store, unreachableRedis(t)))
	request := httptest.NewRequest(http.MethodPost, TrackCancelPath, strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	engine.ServeHTTP(recorder, request)
	return recorder
}

func TestTrackCancelEndsBothReminderRows(t *testing.T) {
	const trackID = "3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0f"
	store := &fakeTrackCancelStore{pending: map[string]bool{trackID: true}}

	recorder := postTrackCancel(t, store, `{"track_id":"`+trackID+`"}`)

	if recorder.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", recorder.Code)
	}
	want := []string{trackID, trackID + ":lead"}
	if len(store.cancelled) != 2 || store.cancelled[0] != want[0] || store.cancelled[1] != want[1] {
		t.Errorf("cancelled = %v, want %v", store.cancelled, want)
	}
}

func TestTrackCancelAnswersTheSameForAnUnknownSession(t *testing.T) {
	store := &fakeTrackCancelStore{pending: map[string]bool{}}

	recorder := postTrackCancel(t, store, `{"track_id":"3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0f"}`)

	// Reporting "no such session" would turn an unguessable id into an oracle,
	// and the caller cannot act on the difference: the card is already gone from
	// its screen either way.
	if recorder.Code != http.StatusNoContent {
		t.Errorf("status = %d, want 204 for an unknown session too", recorder.Code)
	}
}

func TestTrackCancelRejectsAnythingButATrackID(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"not json", `track_id=x`},
		{"missing id", `{}`},
		{"not a uuid", `{"track_id":"../../etc/passwd"}`},
		{"uuid v1", `{"track_id":"3f2a1c7e-9b4d-1a2f-8e1c-5d6b7a8c9e0f"}`},
		{"too short", `{"track_id":"3f2a1c7e-9b4d-4a2f-8e1c"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			store := &fakeTrackCancelStore{pending: map[string]bool{}}
			recorder := postTrackCancel(t, store, c.body)
			if recorder.Code != http.StatusBadRequest {
				t.Errorf("status = %d, want 400", recorder.Code)
			}
			// The whole security argument is that the input is unguessable, so
			// nothing that is not shaped like a minted id may reach the database.
			if len(store.cancelled) != 0 {
				t.Errorf("a malformed id reached the store: %v", store.cancelled)
			}
		})
	}
}

func TestTrackCancelReportsAStoreFailure(t *testing.T) {
	store := &fakeTrackCancelStore{err: errors.New("db down")}

	recorder := postTrackCancel(t, store, `{"track_id":"3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0f"}`)

	if recorder.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", recorder.Code)
	}
}

func TestValidUUIDv4(t *testing.T) {
	if !validUUIDv4("3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0f") {
		t.Error("validUUIDv4() rejected a well-formed v4")
	}
	for _, bad := range []string{
		"",
		"3f2a1c7e9b4d4a2f8e1c5d6b7a8c9e0f",             // no dashes
		"3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0",          // short
		"3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0ff",        // long
		"3f2a1c7e-9b4d-3a2f-8e1c-5d6b7a8c9e0f",         // v3
		"3f2a1c7e_9b4d_4a2f_8e1c_5d6b7a8c9e0f",         // wrong separator
		"3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0g",         // not hex
		"3f2a1c7e-9b4d-4a2f-8e1c-5d6b7a8c9e0f' OR '1'", // long enough to matter
	} {
		if validUUIDv4(bad) {
			t.Errorf("validUUIDv4(%q) = true", bad)
		}
	}
}
