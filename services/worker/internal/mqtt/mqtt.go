package mqtt

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
	"github.com/jackc/pgx/v5/pgconn"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"google.golang.org/protobuf/encoding/protojson"
)

// mqttTopicCfg is a subscription: an MQTT topic pattern and the Redis TTL applied
// to messages cached from it.
type mqttTopicCfg struct {
	pattern string
	ttl     time.Duration
}

var _mqttTopics = mqttTopicConfigs()

func mqttTopicConfigs() []mqttTopicCfg {
	return []mqttTopicCfg{
		{"v2/Bus/Alert/City/+", 5 * time.Minute},
		{"v2/Bus/Alert/InterCity", 5 * time.Minute},
		{"v2/Rail/Metro/Alert/#", 5 * time.Minute},
		{"v3/Rail/TRA/Alert", 5 * time.Minute},
		{"v2/Rail/THSR/AlertInfo", 5 * time.Minute},
	}
}

type MQTTArchiver func(topic string, payload []byte)

// OutboxDB is where route alerts are handed to rider for push dispatch.
type OutboxDB interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func StartMQTT(rc *redis.Client, outbox OutboxDB, archive MQTTArchiver) mqtt.Client {
	return startMQTTWithClient(rc, outbox, archive, mqtt.NewClient)
}

func startMQTTWithClient(rc *redis.Client, outbox OutboxDB, archive MQTTArchiver, createClient func(*mqtt.ClientOptions) mqtt.Client) mqtt.Client {
	clientID := os.Getenv("MQTT_CLIENT_ID")
	username := os.Getenv("MQTT_USERNAME")
	password := os.Getenv("MQTT_PASSWORD")
	if !mqttCredentialsPresent(clientID, username, password) {
		zap.S().Warnw("credentials not set \u2014 skipping MQTT subscriber", "component", "mqtt")
		return nil
	}
	opts := mqttClientOptions(clientID, username, password, rc, outbox, archive)
	c := createClient(opts)
	connectMQTT(c)
	return c
}

func mqttsubscribeall(c mqtt.Client, rc *redis.Client, outbox OutboxDB, archive MQTTArchiver) {
	for _, t := range _mqttTopics {
		pattern, ttl := t.pattern, t.ttl
		tok := c.Subscribe(pattern, 1, func(_ mqtt.Client, msg mqtt.Message) {
			// Archive before normalizing, so a payload this package cannot parse is
			// still kept. Those are the messages most worth having: an alert that
			// never reached a rider leaves no other trace.
			if archive != nil {
				archive(msg.Topic(), msg.Payload())
			}
			mqtthandle(rc, msg, ttl, outbox)
		})
		tok.Wait()
		if err := tok.Error(); err != nil {
			zap.S().Errorw("subscribe failed", "component", "mqtt", "topic", pattern, "err", err)
		} else {
			zap.S().Infow("subscribed", "component", "mqtt", "topic", pattern)
		}
	}
}

func mqtthandle(rc *redis.Client, msg mqtt.Message, ttl time.Duration, outbox OutboxDB) {
	items, ok := normalizeAlerts(msg.Topic(), msg.Payload())
	if !ok {
		zap.S().Errorw("unparseable",
			"component", "mqtt",
			"action", "normalize",
			"event", "unparseable",
			"topic", msg.Topic(),
		)
		return
	}
	publishNormalizedMQTTAlerts(rc, msg.Topic(), items, ttl, outbox)
}

func publishNormalizedMQTTAlerts(rc *redis.Client, topic string, items []*pb.Alert_Item, ttl time.Duration, outbox OutboxDB) {
	payload, err := protojson.Marshal(&pb.Alert_Msg{Items: items})
	if err != nil {
		zap.S().Errorw("marshal failed",
			"component", "mqtt",
			"action", "normalize",
			"event", "marshal_failed",
			"topic", topic,
			"err", err,
		)
		return
	}
	publishMQTTAlerts(rc, topic, shared.MQTTChannel(topic), payload, ttl, outbox, items)
}

func publishMQTTAlerts(rc *redis.Client, topic, key string, payload []byte, ttl time.Duration, outbox OutboxDB, items []*pb.Alert_Item) {
	// A broker push is a top-level entry point: paho calls this on its own
	// goroutine with no parent context to inherit, so the handler owns one.
	ctx := context.Background()
	if err := rc.Set(ctx, key, payload, ttl).Err(); err != nil {
		zap.S().Errorw("redis set failed", "component", "mqtt", "key", key, "err", err)
		return
	}
	if err := rc.Publish(ctx, key, payload).Err(); err != nil {
		zap.S().Errorw("redis publish failed", "component", "mqtt", "key", key, "err", err)
	}
	logRouteAlertEnqueue(ctx, outbox, items, topic)
}

func logRouteAlertEnqueue(ctx context.Context, outbox OutboxDB, items []*pb.Alert_Item, topic string) {
	if err := enqueueRouteAlerts(ctx, outbox, items); err != nil {
		zap.S().Errorw("outbox insert failed", "component", "mqtt", "topic", topic, "err", err)
	}
}

// routeAlertRow is one route_alert_outbox row: one alert on one route.
type routeAlertRow struct {
	dedupeKey, routeType, routeKey, body string
}

// routeAlertRows fans each alert out over the routes it names. The dedupe key
// is route plus alert id, and the id is a hash of the body: TDX republishes an
// ongoing disruption with fresh ids and timestamps but the same text, and that
// must not notify twice, while changed text is a new alert.
func routeAlertRows(items []*pb.Alert_Item) []routeAlertRow {
	var rows []routeAlertRow
	for _, item := range items {
		keys := item.RouteKeys
		if len(keys) == 0 {
			keys = []string{""}
		}
		for _, routeKey := range keys {
			rows = append(rows, routeAlertRow{
				dedupeKey: item.RouteType + "\x00" + routeKey + "\x00" + item.Id,
				routeType: item.RouteType,
				routeKey:  routeKey,
				body:      item.Body,
			})
		}
	}
	return rows
}

func enqueueRouteAlerts(ctx context.Context, outbox OutboxDB, items []*pb.Alert_Item) error {
	if outbox == nil {
		return nil
	}
	return insertRouteAlertRows(ctx, outbox, routeAlertRows(items))
}

func insertRouteAlertRows(ctx context.Context, outbox OutboxDB, rows []routeAlertRow) error {
	for _, row := range rows {
		if _, err := outbox.Exec(ctx, `
			INSERT INTO route_alert_outbox (dedupe_key, route_type, route_key, body)
			VALUES ($1, $2, $3, $4)
			ON CONFLICT (dedupe_key) DO NOTHING`,
			row.dedupeKey, row.routeType, row.routeKey, row.body); err != nil {
			return _oops.With("route_key", row.routeKey).Wrapf(err, "enqueue route alert")
		}
	}
	return nil
}

func normalizeAlerts(topic string, payload []byte) ([]*pb.Alert_Item, bool) {
	routeType := alertRouteType(topic)
	if routeType == "" {
		return nil, false
	}
	var raw any
	if json.Unmarshal(payload, &raw) != nil {
		return nil, false
	}
	return normalizedAlertItems(routeType, strings.Contains(topic, "/InterCity"), alertItems(raw)), true
}

func normalizedAlertItems(routeType string, interCity bool, entries []map[string]any) []*pb.Alert_Item {
	out := make([]*pb.Alert_Item, 0, len(entries))
	at := map[string]int{}
	for _, m := range entries {
		out = appendNormalizedAlert(out, at, routeType, interCity, m)
	}
	return out
}

func appendNormalizedAlert(out []*pb.Alert_Item, at map[string]int, routeType string, interCity bool, m map[string]any) []*pb.Alert_Item {
	title := firstString(m, "NewsTitle", "Title")
	body := alertBody(m, title)
	if body == "" {
		return out
	}
	keys := canonicalAlertKeys(alertRouteKeys(routeType, m), interCity)
	if index, ok := at[body]; ok {
		out[index].RouteKeys = dedupeStrings(append(out[index].RouteKeys, keys...))
		return out
	}
	at[body] = len(out)
	return append(out, &pb.Alert_Item{Id: alertID(body), RouteType: routeType, RouteKeys: keys, Title: title, Body: body, Level: alertLevel(m), TimeUnix: alertTime(m), Department: firstString(m, "Department")})
}

func alertBody(m map[string]any, title string) string {
	body := firstString(m, "Description", "NewsContent", "AlertDescription", "Message")
	if body == "" {
		return title
	}
	return body
}

func alertID(body string) string { return fmt.Sprintf("%x", sha256.Sum256([]byte(body))) }

// alertLevel grades one alert. TDX publishes Status as a string on some feeds
// and a number on others, so the value is compared as text either way.
// Everything that is not an outright suspension is advisory.
func alertLevel(m map[string]any) string {
	if suspendedAlertStatus(alertStatus(m)) {
		return "red"
	}
	return "yellow"
}

func alertStatus(m map[string]any) string {
	for _, key := range []string{"Status", "status"} {
		if value, ok := m[key]; ok && value != nil {
			return strings.ToLower(strings.TrimSpace(fmt.Sprint(value)))
		}
	}
	return ""
}

func suspendedAlertStatus(raw string) bool {
	return raw == "red" || raw == "3" || strings.Contains(raw, "中斷")
}

// alertTime reads when the alert was published, as a Unix timestamp. TDX omits
// the zone on some feeds; those are read as Taipei local time, which is the
// only zone its feeds ever describe. An unreadable time yields 0.
func alertTime(m map[string]any) int64 {
	raw := firstString(m, "UpdateTime", "PublishTime")
	if raw == "" {
		return 0
	}
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04:05", "2006-01-02 15:04:05"} {
		if parsed, err := time.ParseInLocation(layout, raw, _alertLocation); err == nil {
			return parsed.Unix()
		}
	}
	return 0
}

// _alertLocation is the zone TDX timestamps are in when they carry no offset.
// It falls back to a fixed +08:00 so a container without tzdata still reads
// those timestamps correctly rather than shifting them to UTC.
var _alertLocation = func() *time.Location {
	if loc, err := time.LoadLocation("Asia/Taipei"); err == nil {
		return loc
	}
	return alertFallbackLocation()
}()

func alertFallbackLocation() *time.Location {
	return time.FixedZone("CST", 8*60*60)
}

// alertRouteType maps an MQTT topic to the transit type its payload describes,
// or "" for a topic that carries no disruption info.
var _alertTopicTypes = []struct{ pattern, routeType string }{
	{"/Bus/", "bus"}, {"/Metro/", "mrt"}, {"/TRA/", "tra"}, {"/THSR/", "thsr"},
}

func alertRouteType(topic string) string {
	for _, mapping := range _alertTopicTypes {
		if strings.Contains(topic, mapping.pattern) {
			return mapping.routeType
		}
	}
	return ""
}

func alertRouteKeys(routeType string, m map[string]any) []string {
	switch routeType {
	case "bus":
		return busRouteKeys(m)
	case "tra":
		return scopeKeys(m, "Trains", "TrainNo")
	case "mrt":
		return dedupeStrings(append(scopeKeys(m, "Lines", "LineID", "LineNo"),
			scopeKeys(m, "LineSections", "LineID", "LineNo")...))
	}
	return nil
}

func alertItems(raw any) []map[string]any {
	items := rawAlertItems(raw)
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		if m, ok := item.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func rawAlertItems(raw any) []any {
	var items []any
	switch v := raw.(type) {
	case []any:
		items = v
	case map[string]any:
		items = []any{v}
		if nested, ok := v["Alerts"].([]any); ok {
			items = nested
		}
	}
	return items
}

func busRouteKeys(m map[string]any) []string {
	keys := []string{}
	if top := firstString(m, "SubRouteUID", "RouteUID"); top != "" {
		keys = append(keys, top)
	}
	keys = append(keys, scopeKeys(m, "SubRoutes", "SubRouteUID", "SubRouteID")...)
	keys = append(keys, scopeKeys(m, "Routes", "RouteUID", "RouteID")...)
	return dedupeStrings(keys)
}

func scopeKeys(m map[string]any, list string, fields ...string) []string {
	scope, _ := m["Scope"].(map[string]any)
	entries, _ := scope[list].([]any)
	keys := make([]string, 0, len(entries))
	for _, entry := range entries {
		if e, ok := entry.(map[string]any); ok {
			if key := firstString(e, fields...); key != "" {
				keys = append(keys, key)
			}
		}
	}
	return dedupeStrings(keys)
}

// dedupeStrings drops repeats while preserving order.
func dedupeStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	out := values[:0]
	for _, v := range values {
		if _, ok := seen[v]; ok {
			continue
		}
		seen[v] = struct{}{}
		out = append(out, v)
	}
	return out
}

// firstString returns the trimmed value of the first key in keys that maps to a
// non-empty string, or "" if none do. Used to read a value that TDX may publish
// under any of several field names.
func firstString(m map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, ok := m[key].(string); ok && strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func canonicalAlertKeys(keys []string, interCity bool) []string {
	if interCity {
		for i, key := range keys {
			keys[i], _ = shared.CanonicalSubroute("InterCity", key, 0)
		}
		keys = dedupeStrings(keys)
	}
	return keys
}

func mqttCredentialsPresent(clientID, username, password string) bool {
	return clientID != "" && username != "" && password != ""
}

func mqttClientOptions(clientID, username, password string, rc *redis.Client, outbox OutboxDB, archive MQTTArchiver) *mqtt.ClientOptions {
	opts := mqtt.NewClientOptions().
		AddBroker("mqtts://mqtt.transportdata.tw:8883").
		SetClientID(clientID).
		SetUsername(username).
		SetPassword(password).
		SetCleanSession(true).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetConnectRetryInterval(10 * time.Second).
		SetTLSConfig(&tls.Config{}).
		SetOnConnectHandler(func(c mqtt.Client) {
			zap.S().Infow("connected", "component", "mqtt")
			mqttsubscribeall(c, rc, outbox, archive)
		}).
		SetConnectionLostHandler(func(_ mqtt.Client, err error) {
			zap.S().Warnw("connection lost", "component", "mqtt", "err", err)
		})
	return opts
}

func connectMQTT(c mqtt.Client) {
	tok := c.Connect()
	tok.Wait()
	if err := tok.Error(); err != nil {
		zap.S().Errorw("initial connect failed; will auto-retry", "component", "mqtt", "err", err)
	}
}
