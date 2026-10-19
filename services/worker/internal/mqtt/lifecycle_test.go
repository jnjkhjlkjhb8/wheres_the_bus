package mqtt

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

type completedMQTTToken struct{ err error }

func (t completedMQTTToken) Wait() bool                     { return true }
func (t completedMQTTToken) WaitTimeout(time.Duration) bool { return true }
func (t completedMQTTToken) Error() error                   { return t.err }
func (t completedMQTTToken) Done() <-chan struct{} {
	done := make(chan struct{})
	close(done)
	return done
}

type controlledMQTTClient struct {
	paho.Client
	err       error
	topics    []string
	callbacks []paho.MessageHandler
}

func (c *controlledMQTTClient) Connect() paho.Token { return completedMQTTToken{c.err} }
func (c *controlledMQTTClient) Subscribe(topic string, qos byte, callback paho.MessageHandler) paho.Token {
	c.topics = append(c.topics, topic)
	c.callbacks = append(c.callbacks, callback)
	return completedMQTTToken{c.err}
}

type controlledMQTTMessage struct {
	paho.Message
	topic string
	raw   []byte
}

func (m controlledMQTTMessage) Topic() string   { return m.topic }
func (m controlledMQTTMessage) Payload() []byte { return m.raw }

func TestMQTTOptionsAndDisabledCredentials(t *testing.T) {
	for _, missing := range []string{"MQTT_CLIENT_ID", "MQTT_USERNAME", "MQTT_PASSWORD"} {
		t.Setenv("MQTT_CLIENT_ID", "client")
		t.Setenv("MQTT_USERNAME", "user")
		t.Setenv("MQTT_PASSWORD", "pass")
		t.Setenv(missing, "")
		called := false
		if startMQTTWithClient(nil, nil, nil, func(*paho.ClientOptions) paho.Client { called = true; return &controlledMQTTClient{} }) != nil || called {
			t.Fatalf("missing %s still connected", missing)
		}
	}
	t.Setenv("MQTT_CLIENT_ID", "client")
	t.Setenv("MQTT_USERNAME", "user")
	t.Setenv("MQTT_PASSWORD", "pass")
	connected := &controlledMQTTClient{}
	if got := startMQTTWithClient(nil, nil, nil, func(options *paho.ClientOptions) paho.Client {
		if options.ClientID != "client" {
			t.Fatalf("client ID=%s", options.ClientID)
		}
		return connected
	}); got != connected {
		t.Fatal("configured client not returned")
	}
	core, logs := observer.New(zap.DebugLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	defer restore()
	options := mqttClientOptions("client", "user", "pass", nil, nil, nil)
	if options.ClientID != "client" || options.Username != "user" || options.Password != "pass" || !options.CleanSession || !options.AutoReconnect || !options.ConnectRetry || options.ConnectRetryInterval != 10*time.Second || options.TLSConfig == nil {
		t.Fatalf("options=%v", options)
	}
	if len(options.Servers) != 1 || options.Servers[0].String() != "mqtts://mqtt.transportdata.tw:8883" {
		t.Fatalf("brokers=%v", options.Servers)
	}
	c := &controlledMQTTClient{}
	options.OnConnect(c)
	if len(c.topics) != len(_mqttTopics) {
		t.Fatalf("subscriptions=%v", c.topics)
	}
	if logs.FilterMessage("subscribe failed").Len() != 0 || logs.FilterMessage("subscribed").Len() != len(_mqttTopics) {
		t.Fatalf("successful subscription logs=%v", logs.All())
	}
	logs.TakeAll()
	options.OnConnectionLost(c, errors.New("disconnected"))
	connectMQTT(c)
	if logs.FilterMessage("initial connect failed; will auto-retry").Len() != 0 {
		t.Fatal("successful connect logged failure")
	}
	c.err = errors.New("connect failed")
	connectMQTT(c)
	mqttsubscribeall(c, nil, nil, nil)
	if logs.FilterMessage("initial connect failed; will auto-retry").Len() != 1 || logs.FilterMessage("subscribe failed").Len() != len(_mqttTopics) {
		t.Fatalf("failure logs=%v", logs.All())
	}
}

func TestMQTTSubscriptionArchivesBeforePublishingAndOutbox(t *testing.T) {
	addr := os.Getenv("REDIS_TEST_ADDR")
	if addr == "" {
		t.Skip("REDIS_TEST_ADDR required")
	}
	rc := redis.NewClient(&redis.Options{Addr: addr, DB: 12})
	ctx := context.Background()
	topic := "v2/Bus/Alert/City/Taipei"
	key := shared.MQTTChannel(topic)
	t.Cleanup(func() { rc.Del(ctx, key); _ = rc.Close() })
	raw := []byte(`{"NewsTitle":"test","Description":"changed","RouteUID":"TPEquality"}`)
	core, logs := observer.New(zap.DebugLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	defer restore()
	archived := 0
	c := &controlledMQTTClient{}
	outbox := &recordingOutbox{}
	mqttsubscribeall(c, rc, outbox, func(gotTopic string, got []byte) {
		archived++
		if gotTopic != topic || string(got) != string(raw) {
			t.Errorf("archive=%s %s", gotTopic, got)
		}
		if len(outbox.args) >= archived {
			t.Error("outbox preceded archival")
		}
	})
	for _, callback := range c.callbacks {
		callback(c, controlledMQTTMessage{topic: topic, raw: raw})
	}
	if archived != len(_mqttTopics) || len(outbox.args) != len(_mqttTopics) {
		t.Fatalf("archive=%d outbox=%v", archived, outbox.args)
	}
	if value, err := rc.Get(ctx, key).Result(); err != nil || value == "" {
		t.Fatalf("cache=%q %v", value, err)
	}
	if logs.FilterMessage("redis publish failed").Len() != 0 || logs.FilterMessage("outbox insert failed").Len() != 0 {
		t.Fatalf("successful publication logged errors: %v", logs.All())
	}
	ttl := rc.TTL(ctx, key).Val()
	if ttl <= 0 || ttl > 5*time.Minute {
		t.Fatalf("TTL=%v", ttl)
	}
	mqtthandle(rc, controlledMQTTMessage{topic: topic, raw: []byte("bad")}, time.Minute, nil)
	closed := redis.NewClient(&redis.Options{Addr: addr})
	_ = closed.Close()
	mqtthandle(closed, controlledMQTTMessage{topic: topic, raw: raw}, time.Minute, outbox)
	if len(outbox.args) != len(_mqttTopics) {
		t.Fatal("Redis failure still wrote outbox")
	}
}

func TestMQTTEncodingFailureDoesNotPublish(t *testing.T) {
	core, logs := observer.New(zap.DebugLevel)
	restore := zap.ReplaceGlobals(zap.New(core))
	defer restore()
	outbox := &recordingOutbox{}
	publishNormalizedMQTTAlerts(nil, "v2/Bus/Alert/City/Taipei", []*pb.Alert_Item{{Body: string([]byte{0xff})}}, time.Minute, outbox)
	if len(outbox.args) != 0 || logs.FilterMessage("marshal failed").Len() != 1 {
		t.Fatalf("invalid text publication: %v %v", outbox.args, logs.All())
	}
}

func TestMQTTTopicRetentionAndFallbackZone(t *testing.T) {
	topics := mqttTopicConfigs()
	for _, topic := range topics {
		if topic.ttl != 5*time.Minute {
			t.Fatalf("topic %s TTL=%v", topic.pattern, topic.ttl)
		}
	}
	_, offset := time.Date(2026, 1, 1, 0, 0, 0, 0, alertFallbackLocation()).Zone()
	if offset != 28800 {
		t.Fatalf("fallback offset=%d", offset)
	}
	if got := alertLevel(map[string]any{"Status": nil, "status": "3"}); got != "red" {
		t.Fatalf("null status fallback=%s", got)
	}
	if got := alertLevel(map[string]any{"Status": "", "status": "3"}); got != "yellow" {
		t.Fatalf("empty status precedence=%s", got)
	}
}
