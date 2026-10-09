package main

import (
	"testing"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/rider/internal/notify"
)

func TestReminderClaimTimeoutExceedsInFlightSendBound(t *testing.T) {
	if _dispatchTimeout+notify.ArrivalFinalizationTimeout >= notify.ReminderClaimTimeout {
		t.Fatalf(
			"dispatchTimeout (%v) + notify.ArrivalFinalizationTimeout (%v) must stay below notify.ReminderClaimTimeout (%v): otherwise a 'sending' reminder can be reclaimed while its original send is still in flight, double-sending the push",
			_dispatchTimeout, notify.ArrivalFinalizationTimeout, notify.ReminderClaimTimeout,
		)
	}
}
