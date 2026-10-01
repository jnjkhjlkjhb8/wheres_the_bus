package main

import (
	"os"
	"time"

	"go.uber.org/zap"
)

// _health is the liveness marker addStaticCron touches after every cron job
// returns and each cron.Start() call touches once at boot. run() sets it once
// at startup; nothing else reassigns it (docs/go-style/global-mut.md).
var _health *healthFile

// healthFile is the liveness marker touched by cron activity.
type healthFile struct {
	path string
}

// newHealthFile builds a healthFile at path.
func newHealthFile(path string) *healthFile {
	return &healthFile{path: path}
}

func defaultHealthFilePath() string {
	if p := os.Getenv("HEALTH_FILE"); p != "" {
		return p
	}
	return "/tmp/healthy"
}

// touch refreshes the marker's mtime, creating it on the first call. A nil
// receiver (health checks not yet wired up, e.g. in a test that exercises
// addStaticCron directly) is a no-op rather than a panic.
func (h *healthFile) touch() {
	if h == nil {
		return
	}
	now := time.Now()
	if err := os.Chtimes(h.path, now, now); err == nil {
		return
	}
	f, err := os.Create(h.path)
	if err != nil {
		zap.S().Warnw("failed",
			"component", "health",
			"action", "touch",
			"event", "failed",
			"path", h.path,
			"err", err,
		)
		return
	}
	_ = f.Close()
}
