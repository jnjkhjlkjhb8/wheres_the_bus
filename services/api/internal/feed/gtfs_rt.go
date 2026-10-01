package feed

import (
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"net/http"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/installid"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

const (
	_gtfsRTCredentialEnv = "GTFS_RT_CREDENTIAL"
	// _gtfsRTCredentialMinLength matches the metrics credential's floor. The value
	// is a machine-to-machine secret, so there is no reason for it to be short.
	_gtfsRTCredentialMinLength = 32
	// GTFSRTPath is what MOTIS is pointed at. The extension is part of the name
	// because the body is protobuf, not JSON like everything else under /api.
	GTFSRTPath = "/api/gtfs-rt/trip-updates.pb"
	// _gtfsRTContentType is the type GTFS-RT feeds are conventionally served as.
	_gtfsRTContentType = "application/x-protobuf"
)

// GTFSRTCredentialFromEnv reads the endpoint's shared secret. An empty value is
// not an error — it means "do not mount the endpoint" — but a short or padded
// one is, because that is a misconfiguration rather than a decision.
func GTFSRTCredentialFromEnv() (string, error) {
	credential := os.Getenv(_gtfsRTCredentialEnv)
	if credential == "" {
		return "", nil
	}
	if credential != strings.TrimSpace(credential) {
		return "", errors.New(_gtfsRTCredentialEnv + " must not contain leading or trailing whitespace")
	}
	if len(credential) < _gtfsRTCredentialMinLength {
		return "", errors.New(_gtfsRTCredentialEnv + " must be at least 32 characters")
	}
	return credential, nil
}

// RegisterGTFSRTRoutes mounts the feed. Both a credential and a Redis client are
// required: without the first the route would be public, and without the second
// there is nothing to serve.
func RegisterGTFSRTRoutes(r gin.IRoutes, rc *redis.Client, credential string, limit gin.HandlerFunc) {
	if rc == nil || credential == "" {
		return
	}
	r.GET(GTFSRTPath, limit, requireGTFSRTCredential(credential), handleGTFSRT(rc))
}

func requireGTFSRTCredential(expected string) gin.HandlerFunc {
	expectedHash := sha256.Sum256([]byte(expected))
	return func(c *gin.Context) {
		c.Header("Cache-Control", "no-store")
		provided := installid.ParseBearerCredential(c.GetHeader("Authorization"))
		providedHash := sha256.Sum256([]byte(provided))
		if provided == "" || subtle.ConstantTimeCompare(providedHash[:], expectedHash[:]) != 1 {
			c.Header("WWW-Authenticate", "Bearer")
			c.AbortWithStatus(http.StatusUnauthorized)
			return
		}
		c.Next()
	}
}

func handleGTFSRT(rc *redis.Client) gin.HandlerFunc {
	return func(c *gin.Context) {
		payload, err := rc.Get(c.Request.Context(), shared.GTFSRealtimeKey()).Bytes()
		if errors.Is(err, redis.Nil) {
			c.AbortWithStatus(http.StatusServiceUnavailable)
			return
		}
		if err != nil {
			zap.S().Errorw("read failed",
				"component", "gtfs_rt",
				"action", "serve",
				"event", "read_failed",
				"err", err,
			)
			c.AbortWithStatus(http.StatusServiceUnavailable)
			return
		}
		c.Data(http.StatusOK, _gtfsRTContentType, payload)
	}
}
