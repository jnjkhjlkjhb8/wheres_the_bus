package shared

import "testing"

func TestBusRawFeedKeysAreNamespacedPerCity(t *testing.T) {
	if got := BusETARawKey("Taipei"); got != "bus:raw:eta:Taipei" {
		t.Fatalf("BusETARawKey = %q", got)
	}
	if got := BusPositionRawKey("Taipei"); got != "bus:raw:position:Taipei" {
		t.Fatalf("BusPositionRawKey = %q", got)
	}
	if got := BusCityPublishedKey("Taipei"); got != "bus:published:Taipei" {
		t.Fatalf("BusCityPublishedKey = %q", got)
	}
}

func TestMQTTChannelFlattensTopicSeparators(t *testing.T) {
	if got := MQTTChannel("v2/Bus/Alert/City/Taipei"); got != "mqtt:v2:Bus:Alert:City:Taipei" {
		t.Fatalf("MQTTChannel = %q", got)
	}
}

func TestParseLiveDemandKeyInvertsLiveDemandKey(t *testing.T) {
	dataset, partition, ok := ParseLiveDemandKey(LiveDemandKey("bus_eta", "Tainan"))
	if !ok || dataset != "bus_eta" || partition != "Tainan" {
		t.Fatalf("parsed %q %q %v", dataset, partition, ok)
	}
	for _, key := range []string{"live:owned:bike:Taipei", "live:demand:tra", "bus_eta:Tainan"} {
		if _, _, ok := ParseLiveDemandKey(key); ok {
			t.Fatalf("%q parsed as a demand key", key)
		}
	}
	if LiveWakeChannel != "live:wake" {
		t.Fatalf("wake channel=%q", LiveWakeChannel)
	}
}
