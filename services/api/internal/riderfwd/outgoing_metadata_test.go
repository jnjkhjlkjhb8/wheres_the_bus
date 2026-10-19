package riderfwd

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/installid"
	"google.golang.org/grpc/metadata"
)

func TestOutgoingDoesNotInventAbsentCredentials(t *testing.T) {
	for name, incoming := range map[string]metadata.MD{
		"absent":       {},
		"empty values": {installid.MetadataKey: {}, installid.SecretMetadataKey: {}},
		"unrelated":    {"x-firebase-appcheck": {"private-token"}},
	} {
		t.Run(name, func(t *testing.T) {
			ctx := metadata.NewIncomingContext(context.Background(), incoming)
			out, ok := metadata.FromOutgoingContext(Outgoing(ctx))
			if !ok || len(out) != 0 {
				t.Fatalf("outgoing metadata = %v, present = %v; want present empty metadata", out, ok)
			}
		})
	}
}

func TestOutgoingPreservesCredentialValuesAndCallerLifecycle(t *testing.T) {
	incoming := metadata.MD{
		installid.MetadataKey:       {"install-one", "install-two"},
		installid.SecretMetadataKey: {"secret-one", "secret-two"},
		"x-firebase-appcheck":       {"private-token"},
	}
	ctx := metadata.NewIncomingContext(context.Background(), incoming)
	ctx, cancel := context.WithDeadline(ctx, time.Now().Add(time.Hour))
	defer cancel()
	outgoing := Outgoing(ctx)
	got, _ := metadata.FromOutgoingContext(outgoing)
	want := metadata.MD{
		installid.MetadataKey:       {"install-one", "install-two"},
		installid.SecretMetadataKey: {"secret-one", "secret-two"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("outgoing metadata = %v, want %v", got, want)
	}
	deadline, ok := ctx.Deadline()
	outDeadline, outOK := outgoing.Deadline()
	if !ok || !outOK || !outDeadline.Equal(deadline) {
		t.Fatalf("outgoing deadline = %v, present = %v; want %v", outDeadline, outOK, deadline)
	}
	cancel()
	if outgoing.Err() != context.Canceled {
		t.Fatalf("outgoing cancellation = %v, want context.Canceled", outgoing.Err())
	}
}
