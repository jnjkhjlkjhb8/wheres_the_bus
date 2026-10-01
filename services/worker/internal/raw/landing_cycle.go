package raw

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"time"
)

type LandingCycleSource interface {
	DatasetJSONWithLandingCycle(ctx context.Context, table, partCol, partVal string) ([]byte, time.Time, string, error)
}

// IsStale reports whether a partition landed at fetchedAt is too old to load.
func IsStale(fetchedAt time.Time) bool {
	return time.Since(fetchedAt) > StaleAfter
}

func NewLandingCycle() (string, error) {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", _oops.Wrapf(err, "generate random identity")
	}
	return hex.EncodeToString(random[:]), nil
}

const StaleAfter = 27 * time.Hour
