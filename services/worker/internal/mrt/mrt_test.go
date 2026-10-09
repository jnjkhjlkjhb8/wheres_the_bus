package mrt

import (
	"testing"
	"time"
)

// Line BL: BL01 -(110s)- BL02 -(125s)- BL03. Line R: R01 -(100s)- R02.
// Transfer BL02 <-> R01 = 3 min = 180s. Keys lowercased as landing emits them.

// 110 + 125
// 110 + 180 (transfer) + 100
// undirected

// TestParseHHMM covers the text time shapes mrt_schedule actually stores,
// including past-midnight hours ("24:40") and malformed values.
func TestParseHHMM(t *testing.T) {
	cases := []struct {
		in   string
		want int
		ok   bool
	}{
		{"06:00", 360, true},
		{"00:40", 40, true},
		{"24:40", 1480, true},
		{"6:00", 0, false},
		{"", 0, false},
		{"ab:cd", 0, false},
		{"30:00", 0, false},
		{"06:60", 0, false},
	}
	for _, c := range cases {
		got, ok := parseHHMM(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("parseHHMM(%q) = (%d,%v), want (%d,%v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

// TestMrtInService verifies the out-of-service filter: in-window and grace-band
// entries pass, post-close entries are dropped, cross-midnight last trains keep
// matching after 00:00, and keys without schedule rows fail open.
func TestMrtInService(t *testing.T) {
	key := WindowKey("TRTC", "R23", "R", "R28")
	// 06:00 first, 00:40 last (crosses midnight → stored as 1480).
	windows := map[string][]ServiceWindow{
		key: {{first: 360, last: 1480}},
	}
	at := func(h, m int) time.Time {
		return time.Date(2026, 7, 13, h, m, 0, 0, time.UTC)
	}
	cases := []struct {
		name string
		h, m int
		want bool
	}{
		{"midday", 12, 0, true},
		{"just before first within grace", 5, 55, true},
		{"night before first", 4, 0, false},
		{"just past midnight before last", 0, 30, true},
		{"after last plus grace", 1, 6, false},
	}
	for _, c := range cases {
		if got := InService(windows, key, at(c.h, c.m)); got != c.want {
			t.Errorf("%s (%02d:%02d) = %v, want %v", c.name, c.h, c.m, got, c.want)
		}
	}
	if !InService(windows, "TRTC|X|X|X", at(1, 6)) {
		t.Error("unknown key must fail open")
	}
	if !InService(nil, key, at(1, 6)) {
		t.Error("nil window map must fail open")
	}
}
