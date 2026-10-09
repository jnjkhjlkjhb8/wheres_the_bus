package static

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/cache"
	"go.uber.org/zap"
)

const StaticVersionPath = "/api/static-version"

const (
	_staticVersionCacheTTL = 5 * time.Minute

	_staticVersionCacheKey = "static-version"
)

type staticVersionResponse struct {
	Version string `json:"version"`
}

func HandleStaticVersion(db *pgxpool.Pool) gin.HandlerFunc {
	return handleStaticVersion(cache.NewTTLCache(), func(ctx context.Context) (string, error) {
		var completedAt time.Time
		err := db.QueryRow(ctx,
			`SELECT completed_at FROM pipeline_runs
			 WHERE job = 'load' ORDER BY run_date DESC LIMIT 1`,
		).Scan(&completedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return "0", nil
		}
		if err != nil {
			return "", _oops.Wrapf(err, "query pipeline_runs load marker")
		}
		return strconv.FormatInt(completedAt.Unix(), 10), nil
	})
}

// handleStaticVersion is the transport half, split from the query so it can be
// tested without a database.
func handleStaticVersion(cache *cache.TTLCache, read func(context.Context) (string, error)) gin.HandlerFunc {
	return func(c *gin.Context) {
		if body, ok := cache.Get(_staticVersionCacheKey); ok {
			c.Data(http.StatusOK, gin.MIMEJSON, body)
			return
		}
		version, err := read(c.Request.Context())
		if err != nil {
			// The client treats any failure as "keep what you have", so a blip
			// here degrades to the previous behaviour (cache stays valid)
			// rather than to a wipe.
			zap.S().Errorw("read failed",
				"component", "http",
				"action", "static_version",
				"event", "read_failed",
				"err", err,
			)
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": "static version unavailable"})
			return
		}
		body, err := json.Marshal(staticVersionResponse{Version: version})
		if err != nil {
			zap.S().Errorw("encode failed",
				"component", "http",
				"action", "static_version",
				"event", "encode_failed",
				"err", err,
			)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "static version unavailable"})
			return
		}
		cache.Set(_staticVersionCacheKey, body, _staticVersionCacheTTL)
		c.Data(http.StatusOK, gin.MIMEJSON, body)
	}
}
