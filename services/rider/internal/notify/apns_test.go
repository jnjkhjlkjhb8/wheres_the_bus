package notify

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"strings"
	"testing"
)

func testP8(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func TestNewAPNSSenderDisabledWithoutCredentials(t *testing.T) {
	// Every environment runs the tracker; only prod holds Apple credentials. An
	// incomplete set must disable the iOS leg rather than half-configure it.
	for _, missing := range []string{"APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "APNS_P8"} {
		t.Setenv("APNS_KEY_ID", "K1")
		t.Setenv("APNS_TEAM_ID", "T1")
		t.Setenv("APNS_TOPIC", "com.wheres.bus")
		t.Setenv("APNS_P8", testP8(t))
		t.Setenv(missing, "")

		sender, err := NewAPNSSender()
		if err != nil {
			t.Fatalf("NewAPNSSender() without %s error = %v", missing, err)
		}
		if sender != nil {
			t.Errorf("NewAPNSSender() without %s = %v, want nil", missing, sender)
		}
	}
}

func TestNewAPNSSenderRejectsAnUnusableKey(t *testing.T) {
	// Credentials that are present but malformed are a deployment mistake, not
	// a choice to run without push; failing boot says so while someone is still
	// watching the deploy.
	t.Setenv("APNS_KEY_ID", "K1")
	t.Setenv("APNS_TEAM_ID", "T1")
	t.Setenv("APNS_TOPIC", "com.wheres.bus")
	t.Setenv("APNS_P8", "not a pem block")

	if _, err := NewAPNSSender(); err == nil {
		t.Fatal("NewAPNSSender() accepted a key it cannot sign with")
	}
}

func TestAPNSSenderTopicIsTheLiveActivitySubtype(t *testing.T) {
	t.Setenv("APNS_KEY_ID", "K1")
	t.Setenv("APNS_TEAM_ID", "T1")
	t.Setenv("APNS_TOPIC", "com.wheres.bus")
	t.Setenv("APNS_P8", testP8(t))

	sender, err := NewAPNSSender()
	if err != nil {
		t.Fatalf("NewAPNSSender() error = %v", err)
	}
	// The plain bundle id addresses the app; Apple rejects it for this push
	// type, and the rejection is a 400 per station hop rather than anything the
	// rider would see.
	if got := sender.(*apnsSender).topic; got != "com.wheres.bus.push-type.liveactivity" {
		t.Errorf("topic = %q", got)
	}
}

func TestProviderTokenIsCachedAndWellFormed(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	sender := &apnsSender{keyID: "K1", teamID: "T1", key: key}

	token, err := sender.providerToken()
	if err != nil {
		t.Fatalf("providerToken() error = %v", err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token has %d segments, want 3", len(parts))
	}
	// ES256 signs as the raw r||s pair. The ASN.1 form ecdsa.SignASN1 produces
	// is a different length and Apple rejects it.
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}
	if len(signature) != 64 {
		t.Errorf("signature is %d bytes, want the 64-byte r||s pair", len(signature))
	}

	// Apple rejects a provider token refreshed too eagerly, so the second call
	// must reuse the first rather than mint another.
	again, err := sender.providerToken()
	if err != nil {
		t.Fatalf("providerToken() error = %v", err)
	}
	if again != token {
		t.Error("providerToken() minted a second token inside the cache window")
	}
}
