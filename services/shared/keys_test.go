package shared

import "testing"

func TestBusRawFeedKeysAreNamespacedPerCity(t *testing.T) {
	if got := BusETARawKey("Taipei"); got != "bus:raw:eta:Taipei" {
		t.Fatalf("BusETARawKey = %q", got)
	}
	if got := BusPositionRawKey("Taipei"); got != "bus:raw:position:Taipei" {
		t.Fatalf("BusPositionRawKey = %q", got)
	}
}

func TestMQTTChannelFlattensTopicSeparators(t *testing.T) {
	if got := MQTTChannel("v2/Bus/Alert/City/Taipei"); got != "mqtt:v2:Bus:Alert:City:Taipei" {
		t.Fatalf("MQTTChannel = %q", got)
	}
}
