package notify

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

type fakeAPNS struct {
	tokens   []string
	payloads [][]byte
	err      error
}

func (f *fakeAPNS) SendLiveActivity(_ context.Context, token string, payload []byte) error {
	f.tokens = append(f.tokens, token)
	f.payloads = append(f.payloads, payload)
	return f.err
}

func testCard() AlightCard {
	return AlightCard{
		Mode:           "metro",
		Phase:          "riding",
		VehicleLabel:   "板南線",
		VehicleID:      "1021",
		BoardStation:   "台北車站",
		TargetStation:  "南港展覽館",
		NextStation:    "善導寺",
		HopCount:       8,
		CurrentIndex:   2,
		RemainingStops: 6,
		LeadStops:      2,
		LineCode:       "BL",
		LineColorHex:   "#0070BD",
		AsOf:           time.Unix(1_800_000_000, 0),
		StaleAfter:     6 * time.Minute,
	}
}

func apsOf(t *testing.T, payload []byte) map[string]any {
	t.Helper()
	var decoded struct {
		APS map[string]any `json:"aps"`
	}
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	return decoded.APS
}

func TestTrackPusherSendsBothTransports(t *testing.T) {
	fcm, apns := &fakeFCM{}, &fakeAPNS{}
	pusher := NewTrackPusher(fcm, apns)

	if err := pusher.PushCard(context.Background(), testCard(), CardTarget{
		FCMToken: "device-token", ActivityToken: "activity-token",
	}, nil); err != nil {
		t.Fatalf("PushCard() error = %v", err)
	}

	if len(fcm.messages) != 1 {
		t.Fatalf("fcm messages = %d, want 1", len(fcm.messages))
	}
	message := fcm.messages[0]
	if message.Notification != nil {
		t.Error("the card push carries a notification payload; it must be data-only or the shade gets a second, plain card")
	}
	if message.Data["type"] != _trackPushType {
		t.Errorf("data type = %q, want %q", message.Data["type"], _trackPushType)
	}
	if message.Data["remainingStops"] != "6" || message.Data["hopCount"] != "8" {
		t.Errorf("numbers did not survive as strings: %v", message.Data)
	}
	if message.Android == nil || message.Android.Priority != "high" {
		t.Error("android priority must be high or Doze holds the refresh past the stop")
	}

	if len(apns.tokens) != 1 || apns.tokens[0] != "activity-token" {
		t.Fatalf("apns tokens = %v", apns.tokens)
	}
	aps := apsOf(t, apns.payloads[0])
	if aps["event"] != "update" {
		t.Errorf("event = %v, want update", aps["event"])
	}
	if aps["timestamp"] != float64(1_800_000_000) {
		t.Errorf("timestamp = %v, want the reading's own stamp", aps["timestamp"])
	}
	if aps["stale-date"] != float64(1_800_000_000+360) {
		t.Errorf("stale-date = %v, want as-of plus the mode's window", aps["stale-date"])
	}
	if _, ok := aps["alert"]; ok {
		t.Error("a card refresh with no crossing must not alert")
	}
}

func TestTrackPusherEndsTheActivityOnATerminalPhase(t *testing.T) {
	apns := &fakeAPNS{}
	card := testCard()
	card.Phase = "arrived"

	if err := NewTrackPusher(nil, apns).PushCard(
		context.Background(), card, CardTarget{ActivityToken: "activity-token"}, nil,
	); err != nil {
		t.Fatalf("PushCard() error = %v", err)
	}

	aps := apsOf(t, apns.payloads[0])
	if aps["event"] != "end" {
		t.Errorf("event = %v, want end", aps["event"])
	}
	if _, ok := aps["stale-date"]; ok {
		t.Error("an ended card has nothing to go stale")
	}
	// An ending has to be seen: it lingers rather than vanishing under the rider.
	if aps["dismissal-date"] != float64(1_800_000_000+8) {
		t.Errorf("dismissal-date = %v, want a short linger", aps["dismissal-date"])
	}
}

func TestTrackPusherAlertsOnlyOnIOS(t *testing.T) {
	fcm, apns := &fakeFCM{}, &fakeAPNS{}
	alert := AlightAlert("南港展覽館")

	if err := NewTrackPusher(fcm, apns).PushCard(context.Background(), testCard(), CardTarget{
		FCMToken: "device-token", ActivityToken: "activity-token",
	}, &alert); err != nil {
		t.Fatalf("PushCard() error = %v", err)
	}

	aps := apsOf(t, apns.payloads[0])
	body, _ := aps["alert"].(map[string]any)
	if body["title"] != "Get Set" {
		t.Errorf("alert = %v, want the same words the local path uses", body)
	}
	if fcm.messages[0].Notification != nil {
		t.Error("the Android card refresh must stay silent")
	}
}

func TestTrackPusherIsNoOpWithoutTransportsOrTokens(t *testing.T) {
	if pusher := NewTrackPusher(nil, nil); pusher != nil {
		t.Fatal("no transports configured must yield a nil pusher")
	}
	var absent *TrackPusher
	if err := absent.PushCard(context.Background(), testCard(), CardTarget{FCMToken: "t"}, nil); err != nil {
		t.Fatalf("nil pusher PushCard() error = %v", err)
	}

	fcm, apns := &fakeFCM{}, &fakeAPNS{}
	if err := NewTrackPusher(fcm, apns).PushCard(
		context.Background(), testCard(), CardTarget{}, nil,
	); err != nil {
		t.Fatalf("PushCard() error = %v", err)
	}
	if len(fcm.messages) != 0 || len(apns.tokens) != 0 {
		t.Error("a target naming no device and no activity has nothing to push to")
	}
}

func TestTrackPusherReportsBothLegsWhenOneFails(t *testing.T) {
	fcm := &fakeFCM{err: errors.New("fcm down")}
	apns := &fakeAPNS{}

	err := NewTrackPusher(fcm, apns).PushCard(context.Background(), testCard(), CardTarget{
		FCMToken: "device-token", ActivityToken: "activity-token",
	}, nil)
	if err == nil || !errMentions(err, "fcm down") {
		t.Fatalf("PushCard() error = %v, want the FCM failure reported", err)
	}
	// The other leg still ran: two devices can share one session, and one being
	// unreachable is not a reason to freeze the other's card.
	if len(apns.tokens) != 1 {
		t.Error("a failing FCM leg stopped the APNs leg")
	}
}

func TestLiveActivityPayloadMatchesTheWidgetContentState(t *testing.T) {
	payload, err := liveActivityPayload(testCard(), nil)
	if err != nil {
		t.Fatalf("liveActivityPayload() error = %v", err)
	}
	var decoded struct {
		APS struct {
			State map[string]any `json:"content-state"`
		} `json:"aps"`
	}
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}

	fields := swiftContentStateFields(t)
	for name, optional := range fields {
		// An optional may be absent — Swift's synthesized decoder treats a
		// missing key as nil. A non-optional may not: ActivityKit fails the
		// whole decode, and the card silently stops updating.
		if _, ok := decoded.APS.State[name]; !ok && !optional {
			t.Errorf("ContentState.%s is required but never sent, so the push fails to decode", name)
		}
	}
	for name := range decoded.APS.State {
		if _, ok := fields[name]; !ok {
			t.Errorf("payload carries %q, which ContentState has no field for", name)
		}
	}
}

func swiftContentStateFields(t *testing.T) map[string]bool {
	t.Helper()
	const source = "../../../../app/ios/BusLiveActivity/AlightTrackAttributes.swift"
	file, err := os.Open(source)
	if err != nil {
		t.Fatalf("open %s: %v", source, err)
	}
	defer func() { _ = file.Close() }()

	property := regexp.MustCompile(`^\s{8}var (\w+): ([\w<>\[\], ]+\??)`)
	fields := map[string]bool{}
	inState := false
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case strings.Contains(line, "struct ContentState"):
			inState = true
		case inState && line == "    }":
			inState = false
		case inState:
			if match := property.FindStringSubmatch(line); match != nil {
				fields[match[1]] = strings.HasSuffix(match[2], "?")
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("read %s: %v", source, err)
	}
	if len(fields) == 0 {
		t.Fatalf("found no ContentState fields in %s; the guard is not guarding anything", source)
	}
	return fields
}
