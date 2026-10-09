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
		if err := c.ShouldBindJSON(&request); err != nil || !validUUIDv4(request.TrackID) {
			c.Status(http.StatusBadRequest)
			return
		}
		ctx := c.Request.Context()
		cancelled := false
		for _, id := range []string{request.TrackID, mrtLeadReminderID(request.TrackID)} {
			done, err := store.CancelArrivalReminderByID(ctx, id)
			if err != nil {
				zap.S().Warnw("cancel error",
					"component", "mrt_track",
					"action", "http_cancel",
					"event", "cancel_error",
					"track", request.TrackID,
					"err", err,
				)
				c.Status(http.StatusInternalServerError)
				return
			}
			cancelled = cancelled || done
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

func validUUIDv4(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, r := range value {
		switch index {
		case 8, 13, 18, 23:
			if r != '-' {
				return false
			}
		case 14:
			if r != '4' {
				return false
			}
		default:
			if !isHexDigit(r) {
				return false
			}
		}
	}
	return true
}

// TrackCancelStoreFor adapts the pool the HTTP router is built with. Kept here
// rather than threading a store through httpServerConfig: this is the only HTTP
// route that writes, and one constructor is cheaper than a new config field.
func TrackCancelStoreFor(db *pgxpool.Pool) trackCancelStore {
	return firebase.NewFirebaseStore(db)
}
