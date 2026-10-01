package mrttrack

import (
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/mrt"
)

func mrtTestState(current, target, lead int32, status string) *models.MrtTrackState {
	return &models.MrtTrackState{
		TrackId:          "t1",
		TripId:           "201",
		CarId:            "1021",
		PathStationIds:   []string{"BL12", "BL13", "BL14", "BL15", "BL16", "BL17"},
		PathStationNames: []string{"a", "b", "c", "d", "e", "f"},
		TargetIndex:      target,
		CurrentIndex:     current,
		LeadStops:        lead,
		Status:           status,
	}
}

func TestAdvanceMrtTrack(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	recent := now.Add(-time.Minute).Unix()

	cases := []struct {
		name          string
		state         *models.MrtTrackState
		reading       mrtReading
		wantCurrent   int32
		wantRemaining int32
		wantStatus    string
		wantFire      string
		wantTerminal  bool
	}{
		{
			name:          "advance one hop, above lead",
			state:         mrtTestState(1, 4, 1, _mrtStatusTracking),
			reading:       mrtReading{nextIndex: 3, resolved: true, gotInfo: true, hasCountdown: true, countdown: 60 * time.Second},
			wantCurrent:   2,
			wantRemaining: 2,
			wantStatus:    _mrtStatusLeadFired,
			wantFire:      _mrtAlightEventLead,
		},
		{
			name:          "reach lead, fire once",
			state:         mrtTestState(1, 4, 2, _mrtStatusTracking),
			reading:       mrtReading{nextIndex: 3, resolved: true, gotInfo: true, hasCountdown: true, countdown: 30 * time.Second},
			wantCurrent:   2,
			wantRemaining: 2,
			wantStatus:    _mrtStatusLeadFired,
			wantFire:      _mrtAlightEventLead,
		},
		{
			// fire is re-requested every tick inside the lead zone; the claim/fired
			// machinery keeps delivery once-only and lets a released (failed) send
			// retry on a later tick.
			name:          "lead_fired keeps requesting fire for claim-level dedup",
			state:         mrtTestState(2, 4, 2, _mrtStatusLeadFired),
			reading:       mrtReading{nextIndex: 3, resolved: true, gotInfo: true, hasCountdown: true, countdown: 30 * time.Second},
			wantCurrent:   2,
			wantRemaining: 2,
			wantStatus:    _mrtStatusLeadFired,
			wantFire:      _mrtAlightEventLead,
		},
		{
			name:          "arrival clamps and fires from tracking",
			state:         mrtTestState(3, 4, 1, _mrtStatusTracking),
			reading:       mrtReading{nextIndex: 5, resolved: true, gotInfo: true},
			wantCurrent:   4,
			wantRemaining: 0,
			wantStatus:    _mrtStatusArrived,
			wantFire:      _mrtAlightEventAlight,
			wantTerminal:  true,
		},
		{
			name:         "off-path reading is lost",
			state:        mrtTestState(2, 4, 1, _mrtStatusTracking),
			reading:      mrtReading{lost: true},
			wantCurrent:  2,
			wantStatus:   _mrtStatusLost,
			wantFire:     "",
			wantTerminal: true,
		},
		{
			// At the end of a run the carID re-trips (new TripId), so a lost reading
			// within one stop of the target is the arrival, not a lost binding —
			// terminal alight stations are common.
			name:         "lost one stop before target is the arrival",
			state:        mrtTestState(3, 4, 1, _mrtStatusLeadFired),
			reading:      mrtReading{lost: true},
			wantCurrent:  4,
			wantStatus:   _mrtStatusArrived,
			wantFire:     _mrtAlightEventAlight,
			wantTerminal: true,
		},
		{
			name:          "no advance never moves backward",
			state:         mrtTestState(3, 4, 1, _mrtStatusTracking),
			reading:       mrtReading{nextIndex: 2, resolved: true, gotInfo: true},
			wantCurrent:   3,
			wantRemaining: 1,
			wantStatus:    _mrtStatusLeadFired,
			wantFire:      _mrtAlightEventAlight,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// A recent lastProgress keeps the stale path out of these cases.
			c.state.LastProgressAtUnix = recent
			got, fire := advanceMrtTrack(c.state, c.reading, now)
			if got.CurrentIndex != c.wantCurrent {
				t.Errorf("current = %d want %d", got.CurrentIndex, c.wantCurrent)
			}
			if !c.wantTerminal && got.RemainingStops != c.wantRemaining {
				t.Errorf("remaining = %d want %d", got.RemainingStops, c.wantRemaining)
			}
			if got.Status != c.wantStatus {
				t.Errorf("status = %q want %q", got.Status, c.wantStatus)
			}
			if fire != c.wantFire {
				t.Errorf("fire = %q want %q", fire, c.wantFire)
			}
			if c.wantTerminal && got.NextPollAtUnix != 0 {
				t.Errorf("terminal state should zero next_poll_at, got %d", got.NextPollAtUnix)
			}
			if !c.wantTerminal && got.NextPollAtUnix == 0 {
				t.Errorf("live state should schedule next_poll_at")
			}
		})
	}
}

func TestAdvanceMrtTrackStale(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	state := mrtTestState(2, 5, 1, _mrtStatusTracking)
	state.LastProgressAtUnix = now.Add(-11 * time.Minute).Unix()
	// A reading that does not advance the position while the stale window has
	// elapsed ends the session.
	got, fire := advanceMrtTrack(state, mrtReading{}, now)
	if got.Status != _mrtStatusStale {
		t.Errorf("status = %q want stale", got.Status)
	}
	if fire != "" {
		t.Errorf("stale ending must not fire, got %q", fire)
	}
	if got.NextPollAtUnix != 0 {
		t.Error("stale ending should zero next_poll_at")
	}
}

func TestAdvanceMrtTrackStaleWhileFinishingIsArrival(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	state := mrtTestState(4, 5, 1, _mrtStatusLeadFired)
	state.LastProgressAtUnix = now.Add(-11 * time.Minute).Unix()
	// A stall within one stop of the target (typically a persistently empty
	// GetTrainInfo at the end of a run) reports the ride completed, not stale.
	got, fire := advanceMrtTrack(state, mrtReading{}, now)
	if got.Status != _mrtStatusArrived {
		t.Errorf("status = %q want arrived", got.Status)
	}
	if got.CurrentIndex != 5 || got.RemainingStops != 0 {
		t.Errorf("position = %d/%d want clamped to target", got.CurrentIndex, got.RemainingStops)
	}
	if fire != _mrtAlightEventAlight {
		t.Errorf("arrival should request the alight buzz (claim dedups), got %q", fire)
	}
	if got.NextPollAtUnix != 0 {
		t.Error("arrived ending should zero next_poll_at")
	}
}

func TestAdvanceMrtTrackProgressAndNextStation(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	state := mrtTestState(0, 4, 1, _mrtStatusTracking)
	state.LastProgressAtUnix = now.Add(-time.Minute).Unix()
	got, _ := advanceMrtTrack(state, mrtReading{nextIndex: 2, resolved: true, gotInfo: true}, now)
	if got.CurrentIndex != 1 {
		t.Fatalf("current = %d want 1", got.CurrentIndex)
	}
	if got.Progress != 0.25 {
		t.Errorf("progress = %v want 0.25", got.Progress)
	}
	if got.NextStationId != "BL14" || got.NextStationName != "c" {
		t.Errorf("next station = %s/%s want BL14/c", got.NextStationId, got.NextStationName)
	}
}

func TestParseTrtcTrainCountdown(t *testing.T) {
	cases := []struct {
		in   string
		want time.Duration
		ok   bool
	}{
		{"03:39", 3*time.Minute + 39*time.Second, true},
		{"00:00", 0, true},
		{"12:05", 12*time.Minute + 5*time.Second, true},
		{"列車進站", 0, false},
		{"", 0, false},
		{"4:70", 0, false},
	}
	for _, c := range cases {
		got, ok := parseTrtcTrainCountdown(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("parseTrtcTrainCountdown(%q) = %v,%v want %v,%v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestMrtResolvePathIndex(t *testing.T) {
	names := []string{"忠孝新生", "忠孝復興", "港墘", "台北車站"}
	cases := []struct {
		stn  string
		want int
	}{
		{"忠孝新生站", 0},
		{"忠孝復興站", 1},
		{"港漧站", 2},    // known misspelling absorbed via alias
		{"台北車站", 3},   // legitimately ends in 站
		{"南京復興站", -1}, // off the stored path
		{"", -1},
		{"站", -1},
	}
	for _, c := range cases {
		if got := mrtResolvePathIndex(names, c.stn); got != c.want {
			t.Errorf("mrtResolvePathIndex(%q) = %d want %d", c.stn, got, c.want)
		}
	}
}

func TestMrtIsTerminal(t *testing.T) {
	for _, s := range []string{_mrtStatusArrived, _mrtStatusLost, _mrtStatusStale, _mrtStatusCancelled} {
		if !mrtIsTerminal(s) {
			t.Errorf("%q should be terminal", s)
		}
	}
	for _, s := range []string{_mrtStatusTracking, _mrtStatusLeadFired} {
		if mrtIsTerminal(s) {
			t.Errorf("%q should not be terminal", s)
		}
	}
}

func TestMrtAdjacencyRows(t *testing.T) {
	lines := []mrt.AdjacencyRow{
		{LineID: "BL", TravelTimes: []struct {
			FromStationID string `json:"FromStationID"`
			ToStationID   string `json:"ToStationID"`
		}{
			{FromStationID: "BL12", ToStationID: "BL13"},
			{FromStationID: "BL13", ToStationID: "BL14"},
		}},
	}
	rows := mrt.AdjacencyRows(lines, "TRTC")
	// Two segments, both directions each = four directed edges.
	if len(rows) != 4 {
		t.Fatalf("rows = %d want 4", len(rows))
	}
	seen := map[string]bool{}
	for _, r := range rows {
		if r[0] != "TRTC" || r[1] != "BL" {
			t.Errorf("row system/line = %v/%v", r[0], r[1])
		}
		seen[r[2].(string)+"->"+r[3].(string)] = true
	}
	for _, want := range []string{"BL12->BL13", "BL13->BL12", "BL13->BL14", "BL14->BL13"} {
		if !seen[want] {
			t.Errorf("missing directed edge %s", want)
		}
	}
}

func TestMrtCardMoved(t *testing.T) {
	previous := mrtTestState(2, 5, 1, _mrtStatusTracking)
	previous.NextStationName = "c"

	same := mrtTestState(2, 5, 1, _mrtStatusTracking)
	same.NextStationName = "c"
	// The poll schedule moving is not a change the rider can see, and pushing on
	// it would spend the Live Activity budget on a card that says the same thing.
	same.NextPollAtUnix = previous.NextPollAtUnix + 30
	if mrtCardMoved(previous, same) {
		t.Error("mrtCardMoved() = true for a reschedule with no new reading")
	}

	hopped := mrtTestState(3, 5, 1, _mrtStatusTracking)
	hopped.NextStationName = "d"
	if !mrtCardMoved(previous, hopped) {
		t.Error("mrtCardMoved() = false across a station hop")
	}

	ended := mrtTestState(2, 5, 1, _mrtStatusArrived)
	ended.NextStationName = "c"
	if !mrtCardMoved(previous, ended) {
		t.Error("mrtCardMoved() = false for an ending, which is the one reading that must land")
	}
}

func TestMrtCardPhase(t *testing.T) {
	cases := []struct {
		name      string
		status    string
		remaining int32
		lead      int32
		want      string
	}{
		{"far out", _mrtStatusTracking, 6, 2, "riding"},
		// The warm threshold is the rider's own 提前站數 plus the last stop: the
		// same boundary the bar colours on and the vibration fires on.
		{"inside the lead", _mrtStatusTracking, 3, 2, "approaching"},
		{"no lead, last stop", _mrtStatusTracking, 1, 0, "approaching"},
		{"arrived", _mrtStatusArrived, 0, 2, "arrived"},
		{"binding lost", _mrtStatusLost, 4, 2, "lost"},
		// A stale session is a lost binding the tracker could not classify; the
		// card has one word for both, because the rider's move is the same.
		{"stale", _mrtStatusStale, 4, 2, "lost"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := mrtCardPhase(tc.status, tc.remaining, tc.lead); got != tc.want {
				t.Errorf("mrtCardPhase() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestMrtCardCarriesTheDisplayFieldsTheServerCannotDerive(t *testing.T) {
	state := mrtTestState(1, 4, 1, _mrtStatusTracking)
	state.RemainingStops = 3
	state.NextStationName = "c"
	state.VehicleLabel = "板南線"
	state.LineCode = "BL"
	state.LineColorHex = "#0070BD"
	now := time.Unix(1_700_000_000, 0)

	card := mrtCard(state, now)

	if card.VehicleLabel != "板南線" || card.LineCode != "BL" || card.LineColorHex != "#0070BD" {
		t.Errorf("card lost the app's own vocabulary: %+v", card)
	}
	if card.BoardStation != "a" || card.TargetStation != "e" {
		t.Errorf("board/target = %q/%q, want the path's own names", card.BoardStation, card.TargetStation)
	}
	if card.Mode != "metro" || card.Phase != "riding" {
		t.Errorf("mode/phase = %q/%q", card.Mode, card.Phase)
	}
	if card.AsOf != now || card.StaleAfter != _mrtCardStaleAfter {
		t.Errorf("as-of/stale = %v/%v", card.AsOf, card.StaleAfter)
	}
}

func TestMrtCardSurvivesAShortPath(t *testing.T) {
	// A path that does not reach the target index is a broken session, but a
	// missing string is not a reason to drop the refresh a rider is reading.
	state := mrtTestState(1, 9, 1, _mrtStatusTracking)
	card := mrtCard(state, time.Unix(1_700_000_000, 0))
	if card.TargetStation != "" {
		t.Errorf("TargetStation = %q, want empty rather than a panic", card.TargetStation)
	}
}

func TestMrtCardAlertOnlyOnACrossing(t *testing.T) {
	card := mrtCard(mrtTestState(3, 4, 1, _mrtStatusTracking), time.Unix(1_700_000_000, 0))

	if alert := mrtCardAlert("", card); alert != nil {
		t.Errorf("mrtCardAlert() = %v for no crossing, want nil", alert)
	}
	if alert := mrtCardAlert(_mrtAlightEventAlight, card); alert == nil || alert.Title != "Get Set" {
		t.Errorf("mrtCardAlert() = %v for the 下車站 crossing", alert)
	}
	if alert := mrtCardAlert(_mrtAlightEventLead, card); alert == nil || alert.Title != "Ready" {
		t.Errorf("mrtCardAlert() = %v for the 提前提醒站 crossing", alert)
	}
}
