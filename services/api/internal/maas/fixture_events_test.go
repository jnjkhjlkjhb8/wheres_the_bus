package maas

import (
	"testing"
	"time"
)

func awaitMaasEvent[T any](t *testing.T, events <-chan T, name string) T {
	t.Helper()
	select {
	case event := <-events:
		return event
	case <-time.After(time.Second):
		t.Fatalf("%s did not arrive within one second", name)
		var zero T
		return zero
	}
}
