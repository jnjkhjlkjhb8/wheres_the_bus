package notify

import (
	"context"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

type notifyContractTransport func(*http.Request) (*http.Response, error)

func (f notifyContractTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func notifyContractAPNS(t *testing.T) *apnsSender {
	t.Helper()
	t.Setenv("APNS_KEY_ID", "quality-key")
	t.Setenv("APNS_TEAM_ID", "quality-team")
	t.Setenv("APNS_TOPIC", "quality.app")
	t.Setenv("APNS_P8", testP8(t))
	sender, err := NewAPNSSender()
	if err != nil || sender == nil {
		t.Fatalf("sender=%v err=%v", sender, err)
	}
	return sender.(*apnsSender)
}

func notifyContractResponse(request *http.Request) *http.Response {
	return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("")), Request: request}
}

func TestAPNSConstructorRoutesSandboxAndBoundsPublicSendToTenSeconds(t *testing.T) {
	for _, tc := range []struct{ flag, host string }{{"1", "api.sandbox.push.apple.com"}, {"0", "api.push.apple.com"}, {"", "api.push.apple.com"}} {
		t.Run(tc.flag, func(t *testing.T) {
			t.Setenv("APNS_SANDBOX", tc.flag)
			sender := notifyContractAPNS(t)
			var gotHost string
			var deadline time.Time
			var bounded bool
			sender.client.Transport = notifyContractTransport(func(request *http.Request) (*http.Response, error) {
				gotHost = request.URL.Host
				deadline, bounded = request.Context().Deadline()
				return notifyContractResponse(request), nil
			})
			before := time.Now()
			if err := sender.SendLiveActivity(context.Background(), "owned-token", []byte(`{"aps":{"event":"update"}}`)); err != nil {
				t.Fatal(err)
			}
			after := time.Now()
			if gotHost != tc.host || !bounded || deadline.Before(before.Add(10*time.Second)) || deadline.After(after.Add(10*time.Second)) {
				t.Fatalf("host=%q deadline=%v bounded=%v window=[%v,%v]", gotHost, deadline, bounded, before, after)
			}
		})
	}
}

func TestAPNSPublicSendRefreshesProviderAuthorizationAtExactlyFortyFiveMinutes(t *testing.T) {
	sender := notifyContractAPNS(t)
	base := time.Unix(1800000000, 0)
	now := base
	sender.nowFunc = func() time.Time { return now }
	var authorization []string
	sender.client.Transport = notifyContractTransport(func(request *http.Request) (*http.Response, error) {
		authorization = append(authorization, request.Header.Get("authorization"))
		return notifyContractResponse(request), nil
	})
	for _, elapsed := range []time.Duration{0, 45*time.Minute - time.Nanosecond, 45 * time.Minute} {
		now = base.Add(elapsed)
		if err := sender.SendLiveActivity(context.Background(), "owned-token", []byte(`{}`)); err != nil {
			t.Fatal(err)
		}
	}
	if len(authorization) != 3 || authorization[0] != authorization[1] || authorization[2] == authorization[1] {
		t.Fatalf("provider authorization did not reuse then refresh at the boundary: %v", authorization)
	}
	parts := strings.Split(strings.TrimPrefix(authorization[2], "bearer "), ".")
	if len(parts) != 3 {
		t.Fatalf("invalid JWT: %q", authorization[2])
	}
	claims, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Iss string `json:"iss"`
		Iat int64  `json:"iat"`
	}
	if err := json.Unmarshal(claims, &decoded); err != nil || decoded.Iss != "quality-team" || decoded.Iat != base.Add(45*time.Minute).Unix() {
		t.Fatalf("refreshed claims=%+v err=%v", decoded, err)
	}
}

func TestAPNSConstructorPreservesMalformedPKCS8Cause(t *testing.T) {
	t.Setenv("APNS_KEY_ID", "quality-key")
	t.Setenv("APNS_TEAM_ID", "quality-team")
	t.Setenv("APNS_TOPIC", "quality.app")
	t.Setenv("APNS_P8", string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte{0x30, 0x03, 0x02, 0x01}})))
	sender, err := NewAPNSSender()
	var syntax asn1.SyntaxError
	if sender != nil || !errors.As(err, &syntax) {
		t.Fatalf("malformed PKCS8 sender=%v cause=%v", sender, err)
	}
}

func TestRouteAlertDiagnosticsPreserveSendCauseWithoutFalseFailure(t *testing.T) {
	core, logs := observer.New(zap.DebugLevel)
	undo := zap.ReplaceGlobals(zap.New(core))
	t.Cleanup(undo)
	store := &fakeNotificationStore{tokens: []deviceToken{{token: "owned-token"}}, wantRouteType: "bus", wantRouteKey: "owned-route"}
	sender := &fakeFCM{}
	dispatcher := NewDispatcher(store, sender)
	dispatcher.RouteAlert(context.Background(), "bus", "owned-route", "delay")
	if len(sender.messages) != 1 || logs.FilterMessage("send failed").Len() != 0 {
		t.Fatalf("successful alert messages=%d diagnostics=%v", len(sender.messages), logs.All())
	}
	cause := errors.New("quality transport unavailable")
	sender.err = cause
	dispatcher.RouteAlert(context.Background(), "bus", "owned-route", "delay")
	for _, entry := range logs.All() {
		fields := entry.ContextMap()
		if fields["action"] != "route_alert" || fields["event"] != "send_failed" || fields["route_key"] != "owned-route" {
			continue
		}
		for _, field := range entry.Context {
			if err, ok := field.Interface.(error); field.Key == "err" && ok && errors.Is(err, cause) {
				return
			}
		}
	}
	t.Fatalf("route alert lost original transport cause: %v", logs.All())
}

func TestArrivalDispatchIncludesZeroETAAndUsesEnteringStopCopy(t *testing.T) {
	store := &fakeNotificationStore{claimed: make(map[string]bool), reminders: []arrivalReminder{{id: "owned-reminder", token: "owned-token", leadMinutes: 1}}, wantRouteType: "bus", wantRouteKey: "owned-route", wantStopKey: "owned-stop", wantDirection: "0"}
	sender := &fakeFCM{}
	dispatcher := NewDispatcher(store, sender)
	err := dispatcher.Arrivals(context.Background(), []ArrivalEvent{{RouteType: "bus", RouteKey: "owned-route", StopKey: "owned-stop", Direction: "0", ETASeconds: 0}})
	if err != nil || len(sender.messages) != 1 || len(store.firedIDs) != 1 {
		t.Fatalf("zero ETA messages=%v fired=%v err=%v", sender.messages, store.firedIDs, err)
	}
	if sender.messages[0].Notification == nil || sender.messages[0].Notification.Body != "即將進站" || sender.messages[0].Data["body"] != "即將進站" {
		t.Fatalf("entering-stop payload=%+v", sender.messages[0])
	}
}

func TestScheduledClaimFailurePreservesCauseAndDoesNotSendOrFinalize(t *testing.T) {
	cause := errors.New("quality claim unavailable")
	store := &fakeNotificationStore{claimed: make(map[string]bool), due: []arrivalReminder{{id: "owned-reminder", token: "owned-token", leadMinutes: 1}}, claimErr: cause}
	sender := &fakeFCM{}
	err := NewDispatcher(store, sender).FireScheduled(context.Background())
	if !errors.Is(err, cause) || len(sender.messages) != 0 || len(store.firedIDs) != 0 || len(store.releasedIDs) != 0 {
		t.Fatalf("claim failure err=%v messages=%d fired=%v released=%v", err, len(sender.messages), store.firedIDs, store.releasedIDs)
	}
}

func TestTrackPublicPushPreservesAPNSCauseAndOptionalContentState(t *testing.T) {
	for _, configured := range []bool{false, true} {
		card := testCard()
		if !configured {
			card.VehicleID, card.LineCode, card.LineColorHex = "", "", ""
		}
		apns := &fakeAPNS{}
		pusher := NewTrackPusher(nil, apns)
		if err := pusher.PushCard(context.Background(), card, CardTarget{ActivityToken: "owned-token"}, nil); err != nil {
			t.Fatal(err)
		}
		if len(apns.payloads) != 1 {
			t.Fatalf("APNS payloads=%d", len(apns.payloads))
		}
		state, ok := apsOf(t, apns.payloads[0])["content-state"].(map[string]any)
		if !ok {
			t.Fatal("content state missing")
		}
		for key, value := range map[string]string{"vehicleId": card.VehicleID, "lineCode": card.LineCode, "lineColorHex": card.LineColorHex} {
			got, present := state[key]
			if present != configured || (configured && got != value) {
				t.Fatalf("configured=%v optional %s=%v present=%v", configured, key, got, present)
			}
		}
		cause := errors.New("quality APNS unavailable")
		apns.err = cause
		if err := pusher.PushCard(context.Background(), card, CardTarget{ActivityToken: "owned-token"}, nil); !errors.Is(err, cause) {
			t.Fatalf("APNS cause missing: %v", err)
		}
	}
}
