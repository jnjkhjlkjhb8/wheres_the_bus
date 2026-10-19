package installid

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"testing"

	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func TestParseBearerCredential(t *testing.T) {
	for _, tc := range []struct{ header, want string }{
		{"Bearer abc.def-123", "abc.def-123"},
		{"bEaReR\t \tabc", "abc"},
		{"", ""}, {"Bearer", ""}, {"Bearer ", ""},
		{" Bearer abc", ""}, {"Bearer abc ", ""},
		{"Basic abc", ""}, {"Bearerx abc", ""}, {" abc", ""},
		{"Bearer abc def", ""}, {"Bearer abc\tdef", ""},
		{"Bearer abc\rdef", ""}, {"Bearer abc\ndef", ""},
	} {
		t.Run(tc.header, func(t *testing.T) {
			if got := ParseBearerCredential(tc.header); got != tc.want {
				t.Fatalf("credential = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestValidText(t *testing.T) {
	for _, tc := range []struct {
		text  string
		limit int
		want  bool
	}{
		{"", 8, false}, {"a", 0, false}, {"a", 1, true},
		{"ab", 1, false}, {" a", 8, false}, {"a\n", 8, false},
		{"台北", 6, true}, {"台北", 5, false},
	} {
		if got := ValidText(tc.text, tc.limit); got != tc.want {
			t.Errorf("ValidText(%q, %d) = %v, want %v", tc.text, tc.limit, got, tc.want)
		}
	}
}

func incoming(values ...string) context.Context {
	return metadata.NewIncomingContext(context.Background(), metadata.Pairs(values...))
}

func TestCallerID(t *testing.T) {
	for _, tc := range []struct {
		ctx  context.Context
		want string
		ok   bool
	}{
		{context.Background(), "", false},
		{incoming(MetadataKey, "install"), "install", true},
		{incoming(MetadataKey, strings.Repeat("i", 128)), strings.Repeat("i", 128), true},
		{incoming(MetadataKey, strings.Repeat("i", 129)), "", false},
		{incoming(MetadataKey, "one", MetadataKey, "two"), "", false},
		{incoming(MetadataKey, " "), "", false},
	} {
		id, ok := CallerID(tc.ctx)
		if id != tc.want || ok != tc.ok {
			t.Errorf("CallerID = %q, %v; want %q, %v", id, ok, tc.want, tc.ok)
		}
	}
}

func TestSecretHash(t *testing.T) {
	secret := strings.Repeat("s", 32)
	for _, length := range []int{32, 256} {
		value := strings.Repeat("s", length)
		got, err := SecretHash(incoming(MetadataKey, "device", SecretMetadataKey, value), "device")
		want := sha256.Sum256([]byte(value))
		if err != nil || !bytes.Equal(got, want[:]) {
			t.Fatalf("length %d: hash = %x, error = %v; want %x", length, got, err, want)
		}
	}
	for _, ctx := range []context.Context{
		context.Background(),
		incoming(MetadataKey, "other", SecretMetadataKey, secret),
		incoming(MetadataKey, "device"),
		incoming(MetadataKey, "device", SecretMetadataKey, secret, SecretMetadataKey, secret),
		incoming(MetadataKey, "device", SecretMetadataKey, strings.Repeat("s", 31)),
		incoming(MetadataKey, "device", SecretMetadataKey, strings.Repeat("s", 257)),
		incoming(MetadataKey, "device", SecretMetadataKey, " "+secret),
	} {
		hash, err := SecretHash(ctx, "device")
		if hash != nil || status.Code(err) != codes.PermissionDenied {
			t.Errorf("invalid credentials: hash = %x, error = %v", hash, err)
		}
	}
}

type authorizer struct {
	allowed bool
	err     error
	called  bool
	id      string
	hash    []byte
}

func (a *authorizer) AuthorizeInstall(_ context.Context, id string, hash []byte) (bool, error) {
	a.called, a.id, a.hash = true, id, hash
	return a.allowed, a.err
}

func TestAuthorize(t *testing.T) {
	secret := strings.Repeat("s", 32)
	ctx := incoming(MetadataKey, "device", SecretMetadataKey, secret)
	for _, tc := range []struct {
		allowed bool
		err     error
		want    codes.Code
	}{
		{true, nil, codes.OK},
		{false, nil, codes.PermissionDenied},
		{true, errors.New("store unavailable"), codes.Internal},
	} {
		store := &authorizer{allowed: tc.allowed, err: tc.err}
		err := Authorize(ctx, store, "device")
		wantHash := sha256.Sum256([]byte(secret))
		if status.Code(err) != tc.want || !store.called || store.id != "device" || !bytes.Equal(store.hash, wantHash[:]) {
			t.Errorf("authorization: code=%v called=%v id=%q hash=%x", status.Code(err), store.called, store.id, store.hash)
		}
	}
	store := &authorizer{allowed: true}
	if err := Authorize(context.Background(), store, "device"); status.Code(err) != codes.PermissionDenied || store.called {
		t.Fatalf("invalid caller contacted store: called=%v error=%v", store.called, err)
	}
}

func TestNewUUIDv4(t *testing.T) {
	pattern := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	seen := make(map[string]bool)
	for range 32 {
		id, err := NewUUIDv4()
		if err != nil || !pattern.MatchString(id) || seen[id] {
			t.Fatalf("UUID = %q, error = %v, duplicate = %v", id, err, seen[id])
		}
		seen[id] = true
	}
}

func TestRejectedCredentialLogsIdentityMatchWithoutSecret(t *testing.T) {
	core, logs := observer.New(zap.WarnLevel)
	undo := zap.ReplaceGlobals(zap.New(core))
	defer undo()
	for _, tc := range []struct {
		id      string
		matches bool
	}{
		{"device", true}, {"other", false},
	} {
		_, _ = SecretHash(incoming(MetadataKey, tc.id, SecretMetadataKey, "too-short"), "device")
		entry := logs.All()[logs.Len()-1]
		fields := entry.ContextMap()
		if fields["install_id_matches"] != tc.matches || fields["has_install_id"] != true || fields["secret_headers"] != int64(1) {
			t.Fatalf("credential rejection fields = %v", fields)
		}
		if strings.Contains(entry.Message+fmt.Sprint(fields), "too-short") {
			t.Fatalf("credential leaked in rejection message: %s", entry.Message)
		}
	}
}
