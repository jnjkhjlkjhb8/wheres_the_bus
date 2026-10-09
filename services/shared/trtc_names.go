package shared

import (
	"strconv"
	"strings"
)

// Metro Taipei (TRTC) name and countdown helpers, used by both the live TRTC
// feed (realtime) and MRT alight tracking (rider).

// TrtcAliases absorbs known misspellings in the official feed before station
// lookup. Extend as new dirty names surface in resolve-failure logs.
var TrtcAliases = map[string]string{
	"港漧":   "港墘",
	"松山機楊": "松山機場",
}

// ParseMMSS parses a "mm:ss" countdown into total seconds. Minutes are
// unbounded (the feed publishes three-digit waits); seconds must be 0..59.
func ParseMMSS(s string) (int, bool) {
	minutes, seconds, found := strings.Cut(s, ":")
	if !found {
		return 0, false
	}
	mi, errMin := strconv.Atoi(minutes)
	si, errSec := strconv.Atoi(seconds)
	if errMin != nil || errSec != nil {
		return 0, false
	}
	if mi < 0 || si < 0 || si > 59 {
		return 0, false
	}
	return mi*60 + si, true
}

// TrtcLinePrefix returns the line letters of a station ID ("BL12" → "BL").
func TrtcLinePrefix(stationID string) string {
	for i, r := range stationID {
		if r >= '0' && r <= '9' {
			return stationID[:i]
		}
	}
	return stationID
}
