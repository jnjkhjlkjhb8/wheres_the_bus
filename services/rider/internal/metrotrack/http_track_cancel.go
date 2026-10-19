package metrotrack

import (
	"context"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/firebase"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

const TrackCancelPath = "/api/track/cancel"

// HTTPTrackCancelRateLimit bounds the endpoint. One press ends one ride, so a
// device has no honest reason to call this more than a handful of times an hour;
// the limit is set for a retry loop, not for traffic.
const HTTPTrackCancelRateLimit = 20

type trackCancelRequest struct {
	TrackID string `json:"track_id"`
}

// trackCancelStore is the cancel surface, satisfied by *firebaseStore.
type trackCancelStore interface {
	CancelArrivalReminderByID(ctx context.Context, reminderID string) (bool, error)
}

func HandleTrackCancel(store trackCancelStore, rc *redis.Client) gin.HandlerFunc {
	return func(c *gin.Context) {
		var request trackCancelRequest
		if !bindTrackCancelRequest(c, &request) {
			c.Status(http.StatusBadRequest)
			return
		}
		ctx := c.Request.Context()
		cancelled, err := cancelHTTPTrackRows(ctx, store, request.TrackID)
		if err != nil {
			zap.S().Warnw("cancel error", "component", "mrt_track", "action", "http_cancel", "event", "cancel_error", "track", request.TrackID, "err", err)
			c.Status(http.StatusInternalServerError)
			return
		}
		if cancelled {
			publishCancelledTrackState(ctx, rc, request.TrackID)
			zap.S().Infow("cancelled",
				"component", "mrt_track",
				"action", "http_cancel",
				"event", "cancelled",
				"track", request.TrackID,
			)
		}
		c.Status(http.StatusNoContent)
	}
}

func bindTrackCancelRequest(c *gin.Context, request *trackCancelRequest) bool {
	if err := c.ShouldBindJSON(request); err != nil {
		return false
	}
	return validUUIDv4(request.TrackID)
}

func cancelHTTPTrackRows(ctx context.Context, store trackCancelStore, trackID string) (bool, error) {
	cancelled := false
	for _, id := range []string{trackID, mrtLeadReminderID(trackID)} {
		done, err := store.CancelArrivalReminderByID(ctx, id)
		if err != nil {
			return false, err
		}
		cancelled = cancelled || done
	}
	return cancelled, nil
}

func validUUIDv4(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, r := range value {
		if !validUUIDRune(index, r) {
			return false
		}
	}
	return true
}

func validUUIDRune(index int, r rune) bool {
	switch index {
	case 8, 13, 18, 23:
		return r == '-'
	case 14:
		return r == '4'
	default:
		return isHexDigit(r)
	}
}

// TrackCancelStoreFor adapts the pool the HTTP router is built with. Kept here
// rather than threading a store through httpServerConfig: this is the only HTTP
// route that writes, and one constructor is cheaper than a new config field.
func TrackCancelStoreFor(db *pgxpool.Pool) trackCancelStore {
	return firebase.NewFirebaseStore(db)
}
