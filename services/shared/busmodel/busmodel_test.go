package busmodel

import (
	"encoding/json"
	"testing"
)

// TDX sends IsLastBus as a JSON boolean and some cities omit it. A numeric
// field rejected the first element and dropped the whole city's ETA.
func TestRawEstimatedDecodesTDXIsLastBus(t *testing.T) {
	var got []RawEstimated
	body := `[{"StopUID":"A","IsLastBus":true},{"StopUID":"B","IsLastBus":false},{"StopUID":"C"}]`
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatal(err)
	}
	if !got[0].IsLastBus || got[1].IsLastBus || got[2].IsLastBus {
		t.Fatalf("IsLastBus = %v %v %v, want true false false", got[0].IsLastBus, got[1].IsLastBus, got[2].IsLastBus)
	}
}
