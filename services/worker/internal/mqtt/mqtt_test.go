package mqtt

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

// Within lead, but a different bus is arriving: no push.

// The pinned plate arrives: push.

func TestNormalizeAlertsRequireIdentity(t *testing.T) {
	got, ok := normalizeAlerts("v2/Bus/News/City/Taipei", []byte(`{"Description":"x"}`))
	if !ok || len(got) != 1 || len(got[0].RouteKeys) != 0 {
		t.Fatalf("route-less bus news must parse with no keys: ok=%v got=%v", ok, got)
	}
	got, _ = normalizeAlerts("v2/Bus/News/City/Taipei", []byte(`[{"SubRouteUID":"R1","Description":"x"},{"SubRouteUID":"R1","Description":"x"}]`))
	if len(got) != 1 || len(got[0].RouteKeys) != 1 || got[0].RouteKeys[0] != "R1" {
		t.Fatalf("got=%v", got)
	}
	if got, _ := normalizeAlerts("v2/Bus/News/City/Taipei", []byte(`[{"SubRouteUID":"R1"}]`)); len(got) != 0 {
		t.Fatalf("bodyless alert leaked: %v", got)
	}
}

// TestNormalizeAlertsCapturesDepartment verifies the publishing department
// TDX names on the alert is carried through as-is, so the app can label a row
// by its real publisher rather than a hardcoded city name.
func TestNormalizeAlertsCapturesDepartment(t *testing.T) {
	got, ok := normalizeAlerts("v2/Bus/Alert/City/Taipei", []byte(`[{"Department":"臺北市公共運輸處","Description":"x"}]`))
	if !ok || len(got) != 1 || got[0].Department != "臺北市公共運輸處" {
		t.Fatalf("got=%v ok=%v", got, ok)
	}
	got, ok = normalizeAlerts("v2/Bus/Alert/City/Taipei", []byte(`[{"Description":"x"}]`))
	if !ok || len(got) != 1 || got[0].Department != "" {
		t.Fatalf("missing Department must yield empty, got=%v ok=%v", got, ok)
	}
}

// A payload that cannot be understood must not become an empty snapshot: the
// snapshot is what seeds every new subscriber, so writing nothing over the last
// good one would blank the alert list for everyone.
func TestNormalizeAlertsRejectsUnparseablePayload(t *testing.T) {
	if _, ok := normalizeAlerts("v2/Bus/News/City/Taipei", []byte(`not json`)); ok {
		t.Fatal("malformed JSON reported as understood")
	}
	if _, ok := normalizeAlerts("v2/Bike/Availability/Taipei", []byte(`[]`)); ok {
		t.Fatal("non-alert topic reported as understood")
	}
	// A valid but empty payload is TDX saying the disruption cleared, and must
	// be written through so the list actually empties.
	if got, ok := normalizeAlerts("v2/Bus/News/City/Taipei", []byte(`[]`)); !ok || len(got) != 0 {
		t.Fatalf("cleared payload = (%v, %v), want an understood empty snapshot", got, ok)
	}
}

func TestNormalizeAlertsPerTypeScoping(t *testing.T) {
	tra, _ := normalizeAlerts("v3/Rail/TRA/Alert", []byte(`{"AuthorityCode":"TRA","Alerts":[
		{"AlertID":"A1","Description":"停駛","Scope":{"Trains":[{"TrainNo":"123"},{"TrainNo":"456"}]}}
	]}`))
	if len(tra) != 1 || tra[0].RouteType != "tra" || len(tra[0].RouteKeys) != 2 ||
		tra[0].RouteKeys[0] != "123" || tra[0].RouteKeys[1] != "456" {
		t.Fatalf("tra alerts = %+v, want one alert scoped to both trains", tra)
	}
	thsr, _ := normalizeAlerts("v2/Rail/THSR/AlertInfo", []byte(`[
		{"AlertID":"A1","Description":"delay","Scope":{"LineSections":[{"LineID":"THSR"}]}}
	]`))
	if len(thsr) != 1 || thsr[0].RouteType != "thsr" || len(thsr[0].RouteKeys) != 0 {
		t.Fatalf("thsr alerts = %+v, want one system-wide alert", thsr)
	}
	// Metro lines are keys now: a 收藏 of a station on BL resolves to BL, so a
	// BL disruption must not blast every metro subscriber.
	mrt, _ := normalizeAlerts("v2/Rail/Metro/Alert/TRTC", []byte(`{"AuthorityCode":"TRTC","Alerts":[
		{"AlertID":"A1","Description":"號誌異常","Scope":{"Lines":[{"LineID":"BL"}]}}
	]}`))
	if len(mrt) != 1 || mrt[0].RouteType != "mrt" || len(mrt[0].RouteKeys) != 1 || mrt[0].RouteKeys[0] != "BL" {
		t.Fatalf("mrt alerts = %+v, want one alert keyed to line BL", mrt)
	}
	// A metro alert that names no line stays system-wide.
	wide, _ := normalizeAlerts("v2/Rail/Metro/Alert/TRTC", []byte(`{"AuthorityCode":"TRTC","Alerts":[
		{"AlertID":"A2","Description":"全系統停止服務"}
	]}`))
	if len(wide) != 1 || len(wide[0].RouteKeys) != 0 {
		t.Fatalf("unscoped mrt alert = %+v, want no keys", wide)
	}
}

func TestNormalizeAlertsParseBusAlertTopic(t *testing.T) {
	got, _ := normalizeAlerts("v2/Bus/Alert/City/Taipei", []byte(`[
		{"AlertID":"A1","Title":"改道","Description":"因道路施工改道","Status":1,"UpdateTime":"2026-07-26T09:30:00+08:00"}
	]`))
	if len(got) != 1 {
		t.Fatalf("alerts = %+v, want 1 from a Bus/Alert payload", got)
	}
	item := got[0]
	if item.RouteType != "bus" || item.Body != "因道路施工改道" || item.Title != "改道" ||
		item.Level != "yellow" || item.TimeUnix != 1785029400 {
		t.Fatalf("alert = %+v", item)
	}
	if item.Id != alertID("因道路施工改道") {
		t.Fatalf("id = %q, want the body hash", item.Id)
	}
}

// A suspension is graded red whether TDX publishes Status as a string or a
// number; everything else is advisory.
func TestAlertLevelGrading(t *testing.T) {
	tests := []struct {
		payload string
		want    string
	}{
		{`{"Description":"x","Status":3}`, "red"},
		{`{"Description":"x","Status":"red"}`, "red"},
		{`{"Description":"x","Status":"服務中斷"}`, "red"},
		{`{"Description":"x","Status":1}`, "yellow"},
		{`{"Description":"x"}`, "yellow"},
	}
	for _, tt := range tests {
		got, _ := normalizeAlerts("v3/Rail/TRA/Alert", []byte(tt.payload))
		if len(got) != 1 || got[0].Level != tt.want {
			t.Fatalf("%s level = %+v, want %s", tt.payload, got, tt.want)
		}
	}
}

// TestAlertTimeParsesEveryTDXLayout covers the three UpdateTime/PublishTime
// shapes TDX publishes across feeds, plus the fallback to 0 when neither field
// parses. All three timestamps name the same instant, so they must agree.
func TestAlertTimeParsesEveryTDXLayout(t *testing.T) {
	const want = 1785029400 // 2026-07-26T09:30:00+08:00
	tests := []struct {
		payload string
		want    int64
	}{
		{`{"Description":"x","UpdateTime":"2026-07-26T09:30:00+08:00"}`, want},
		{`{"Description":"x","UpdateTime":"2026-07-26T09:30:00"}`, want},
		{`{"Description":"x","UpdateTime":"2026-07-26 09:30:00"}`, want},
		{`{"Description":"x","PublishTime":"2026-07-26T09:30:00+08:00"}`, want},
		{`{"Description":"x","UpdateTime":"not a time"}`, 0},
		{`{"Description":"x"}`, 0},
	}
	for _, tt := range tests {
		got, _ := normalizeAlerts("v3/Rail/TRA/Alert", []byte(tt.payload))
		if len(got) != 1 || got[0].TimeUnix != tt.want {
			t.Fatalf("%s time = %+v, want %d", tt.payload, got, tt.want)
		}
	}
}

// TestNormalizeAlertsFoldsRepeatedBodies covers the TDX Bus/Alert shape where
// the affected routes live in Scope.SubRoutes / Scope.Routes rather than at the
// top level: one disruption collects every route it scopes into one alert.
func TestNormalizeAlertsFoldsRepeatedBodies(t *testing.T) {
	got, _ := normalizeAlerts("v2/Bus/Alert/City/Taipei", []byte(`[{
		"AlertID":"A1","Title":"停駛","Description":"因道路施工停駛",
		"Scope":{"SubRoutes":[{"SubRouteID":"10132"},{"SubRouteUID":"TPE10133"}],"Routes":[{"RouteID":"10132"}]}
	}]`))
	if len(got) != 1 {
		t.Fatalf("alerts = %+v, want one alert", got)
	}
	keys := map[string]bool{}
	for _, key := range got[0].RouteKeys {
		keys[key] = true
	}
	if len(got[0].RouteKeys) != 2 || !keys["10132"] || !keys["TPE10133"] {
		t.Fatalf("keys = %+v, want one per scoped route (deduped)", got[0].RouteKeys)
	}
}

// TestAlertItemsUnwrapEnvelope covers the metro/TRA authority envelope, which
// carries several alerts per message instead of a bare array.
func TestAlertItemsUnwrapEnvelope(t *testing.T) {
	decode := func(raw string) []map[string]any {
		var value any
		if err := json.Unmarshal([]byte(raw), &value); err != nil {
			t.Fatalf("decode %s: %v", raw, err)
		}
		return alertItems(value)
	}
	got := decode(`{"AuthorityCode":"TRTC","Alerts":[{"AlertID":"A1"},{"AlertID":"A2"}]}`)
	if len(got) != 2 || got[1]["AlertID"] != "A2" {
		t.Fatalf("items = %+v, want the two enveloped alerts", got)
	}
	if got := decode(`{"AlertID":"A1"}`); len(got) != 1 {
		t.Fatalf("bare object must parse as one alert: %+v", got)
	}
}

func TestInterCityAlertsUseCanonicalSubrouteIdentity(t *testing.T) {
	got, _ := normalizeAlerts("v2/Bus/News/InterCity", []byte(`[
		{"SubRouteUID":"THB902301","Description":"outbound"},
		{"SubRouteUID":"THB902302","Description":"inbound"}
	]`))
	if len(got) != 2 {
		t.Fatalf("alerts = %+v", got)
	}
	for i := range got {
		if len(got[i].RouteKeys) != 1 || got[i].RouteKeys[0] != "THB9023" {
			t.Fatalf("alert[%d] keys = %v, want canonical THB9023", i, got[i].RouteKeys)
		}
	}
}

// TestRouteAlertCoversEveryTransitType pins that disruption pushes reach all
// four subscribable types, and that an unknown type stays a no-op.

// TestLineWideAlertTitlesBroaderScope pins the empty-key path: a line-wide
// disruption still dispatches (to every subscriber of that type) and is
// labelled 營運通阻 rather than naming one route.

// Arrival reminders are transport-agnostic: metro/TRA/THSR fire the same way
// as bus once their ETA source computes a usable etaSeconds.

// A later tick that still sees the (unremoved) reminder must not resend it:
// the claim guard prevents duplicate pushes across ticks.

// Release failed, so the reminder must remain claimed (stuck in
// 'sending') rather than silently freed for the next tick to skip.

// TDX republishes an ongoing disruption with a fresh UpdateTime and
// sometimes a fresh AlertID while the text never changes. Identity is the
// body, so a republish must not re-notify.

// Text that actually changed is a new alert and must reach the rider.

// The claim window has to outlast the disruption it dedupes, or a multi-day
// closure re-notifies every time it lapses.

// A second attempt loses the claim (already fired) and does not re-send.

func TestRouteAlertRowsDedupeIdentity(t *testing.T) {
	first, _ := normalizeAlerts("v2/Bus/News/City/Taipei", []byte(`{"SubRouteUID":"R1","NewsID":"A1","Description":"x"}`))
	// TDX republishes an ongoing disruption with a fresh id and UpdateTime but
	// the same text; it must land on the same row.
	republished, _ := normalizeAlerts("v2/Bus/News/City/Taipei", []byte(
		`{"SubRouteUID":"R1","NewsID":"A2","UpdateTime":"2026-07-26T11:00:00+08:00","Description":"x"}`))
	changed, _ := normalizeAlerts("v2/Bus/News/City/Taipei", []byte(`{"SubRouteUID":"R1","NewsID":"A2","Description":"已排除"}`))

	a, b, c := routeAlertRows(first), routeAlertRows(republished), routeAlertRows(changed)
	if len(a) != 1 || len(b) != 1 || len(c) != 1 {
		t.Fatalf("rows = %d/%d/%d, want one each", len(a), len(b), len(c))
	}
	if a[0].dedupeKey != b[0].dedupeKey {
		t.Fatalf("republished identical body got a new key: %q vs %q", a[0].dedupeKey, b[0].dedupeKey)
	}
	if a[0].dedupeKey == c[0].dedupeKey {
		t.Fatal("changed body reused the old key; the rider would never hear about it")
	}
	if a[0].routeType != "bus" || a[0].routeKey != "R1" || a[0].body != "x" {
		t.Fatalf("row = %+v", a[0])
	}
}

func TestRouteAlertRowsFanOutPerRoute(t *testing.T) {
	rows := routeAlertRows([]*pb.Alert_Item{{RouteType: "bus", RouteKeys: []string{"R1", "R2"}, Id: "A1", Body: "x"}})
	if len(rows) != 2 || rows[0].dedupeKey == rows[1].dedupeKey {
		t.Fatalf("same alert on two routes = %+v, want two distinct rows", rows)
	}
	lineWide := routeAlertRows([]*pb.Alert_Item{{RouteType: "tra", Id: "A1", Body: "x"}})
	if len(lineWide) != 1 || lineWide[0].routeKey != "" {
		t.Fatalf("alert without routes = %+v, want one line-wide row", lineWide)
	}
}

type recordingOutbox struct{ args [][]any }

func (r *recordingOutbox) Exec(_ context.Context, _ string, args ...any) (pgconn.CommandTag, error) {
	r.args = append(r.args, args)
	return pgconn.CommandTag{}, nil
}

func TestEnqueueRouteAlertsWritesEveryRow(t *testing.T) {
	out := &recordingOutbox{}
	items := []*pb.Alert_Item{{RouteType: "bus", RouteKeys: []string{"R1", "R2"}, Id: "A1", Body: "x"}}
	if err := enqueueRouteAlerts(context.Background(), out, items); err != nil {
		t.Fatal(err)
	}
	if len(out.args) != 2 {
		t.Fatalf("inserts = %d, want 2", len(out.args))
	}
	if err := enqueueRouteAlerts(context.Background(), nil, items); err != nil {
		t.Fatalf("nil outbox = %v, want a no-op", err)
	}
}
