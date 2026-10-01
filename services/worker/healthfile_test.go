package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/robfig/cron/v3"
)

func TestTouchHealthFileCreatesAndRefreshes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "healthy")
	h := newHealthFile(path)

	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("marker must not exist before the first touch, stat err = %v", err)
	}

	h.touch()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("expected marker to exist after touch, stat err = %v", err)
	}
	firstMtime := info.ModTime()

	// mtime resolution on some filesystems is coarse; sleep past it so a
	// refreshed touch is provably later, not just equal.
	time.Sleep(10 * time.Millisecond)
	h.touch()
	info, err = os.Stat(path)
	if err != nil {
		t.Fatalf("expected marker to still exist after second touch, stat err = %v", err)
	}
	if !info.ModTime().After(firstMtime) {
		t.Fatalf("second touch did not advance mtime: first=%v second=%v", firstMtime, info.ModTime())
	}
}

func TestAddStaticCronTouchesHealthFileAfterJob(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "healthy")
	// addStaticCron reaches the marker through the package-level _health
	// instance (set once at startup in run(), same pattern as _archive/
	// raw.DB); point it at a test-local file for the duration of this test.
	prev := _health
	_health = newHealthFile(path)
	defer func() { _health = prev }()

	r := cron.New(cron.WithSeconds())
	ran := make(chan struct{}, 1)
	id, err := addStaticCron(r, "@every 1h", func() {
		ran <- struct{}{}
	})
	if err != nil {
		t.Fatalf("addStaticCron: %v", err)
	}
	r.Entry(id).Job.Run()
	select {
	case <-ran:
	default:
		t.Fatal("job did not run")
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected marker to exist after job tick, stat err = %v", err)
	}
}
