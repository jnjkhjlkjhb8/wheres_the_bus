package bus

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

func TestLiveDecodersRejectWrongDelimitersAndTrailingData(t *testing.T) {
	for _, body := range []string{`{}`, `[] {}`, `[{"StationUID":"S1"}] trailing`} {
		t.Run(body, func(t *testing.T) {
			err := pipeline.DecodeLiveItems(json.NewDecoder(strings.NewReader(body)), func(struct{ StationUID string }) error { return nil })
			if err == nil {
				t.Fatalf("pipeline.DecodeLiveItems(%q) returned nil", body)
			}

			if _, err := decodeBusEtaArray(json.NewDecoder(strings.NewReader(body))); err == nil {
				t.Fatalf("decodeBusEtaArray(%q) returned nil", body)
			}
		})
	}
}
