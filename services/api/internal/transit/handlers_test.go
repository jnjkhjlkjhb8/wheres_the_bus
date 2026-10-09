package transit

import "testing"

func TestUsableBusEtaPayloadRejectsEmptyPayload(t *testing.T) {
	if usableBusEtaPayload(nil) {
		t.Fatal("nil payload should not be sent")
	}
	if usableBusEtaPayload([]byte{}) {
		t.Fatal("empty payload should not be sent")
	}
	if !usableBusEtaPayload([]byte{1}) {
		t.Fatal("non-empty payload should be sent")
	}
}
