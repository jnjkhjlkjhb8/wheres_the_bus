package rail

import (
	"testing"
	"time"
)

func TestParseRailDate(t *testing.T) {
	// The app sends 'yyyy-MM-dd'; the router must key/query on that exact date,
	// not the zero time (which yielded train_date='0001-01-01' -> NotFound).
	got := parseRailDate("2026-07-07")
	if got.Format(time.DateOnly) != "2026-07-07" {
		t.Fatalf("DateOnly: got %q, want 2026-07-07", got.Format(time.DateOnly))
	}

	// RFC3339 stays supported for any legacy caller.
	got = parseRailDate("2026-07-07T00:00:00Z")
	if got.Format(time.DateOnly) != "2026-07-07" {
		t.Fatalf("RFC3339: got %q, want 2026-07-07", got.Format(time.DateOnly))
	}

	// Garbage falls back to the zero time.
	if !parseRailDate("nonsense").IsZero() {
		t.Fatal("expected zero time for unparseable date")
	}
}

func TestRailCacheDateCollapsesSpellings(t *testing.T) {
	dateOnly := railCacheDate("2026-07-07")
	rfc := railCacheDate("2026-07-07T00:00:00Z")
	if dateOnly != rfc {
		t.Fatalf("one service day, two keys: %q vs %q", dateOnly, rfc)
	}
	if dateOnly != "2026-07-07" {
		t.Fatalf("got %q, want the queried date 2026-07-07", dateOnly)
	}
}

func TestRailCacheStationCollapsesSpellings(t *testing.T) {
	if got, want := railCacheStation("臺北"), railCacheStation("台北"); got != want {
		t.Fatalf("one station, two keys: %q vs %q", got, want)
	}
	if got := railCacheStation("  台北 "); got != "台北" {
		t.Fatalf("surrounding space survived into the key: %q", got)
	}
	if got := railCacheStation("1000"); got != "1000" {
		t.Fatalf("numeric id must pass through unchanged, got %q", got)
	}
}
