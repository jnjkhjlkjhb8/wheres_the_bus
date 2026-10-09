package notify

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	_apnsProduction = "https://api.push.apple.com"
	_apnsSandbox    = "https://api.sandbox.push.apple.com"
	// _apnsTokenTTL refreshes the provider JWT well inside Apple's one-hour
	// ceiling. Apple rejects a token younger than 20 minutes on refresh, so this
	// sits between the two bounds rather than near either.
	_apnsTokenTTL = 45 * time.Minute
	// _apnsTimeout bounds one push. A station hop is the unit of work here, and a
	// push that has not landed within this is better dropped than queued behind
	// the next hop's.
	_apnsTimeout = 10 * time.Second
)

// APNSSender delivers one Live Activity update to one activity push token.
type APNSSender interface {
	SendLiveActivity(ctx context.Context, token string, payload []byte) error
}

// apnsSender is the live APNs client: a provider-token JWT (ES256 over the p8
// key), cached until it ages out, and an HTTP/2 client Go builds for us because
// the endpoint is TLS.
type apnsSender struct {
	client  *http.Client
	host    string
	topic   string
	keyID   string
	teamID  string
	key     *ecdsa.PrivateKey
	nowFunc func() time.Time

	mu       sync.Mutex
	token    string
	tokenAge time.Time
}

func NewAPNSSender() (APNSSender, error) {
	keyID := os.Getenv("APNS_KEY_ID")
	teamID := os.Getenv("APNS_TEAM_ID")
	topic := os.Getenv("APNS_TOPIC")
	p8 := os.Getenv("APNS_P8")
	if keyID == "" || teamID == "" || topic == "" || p8 == "" {
		return nil, nil
	}
	key, err := parseP8(p8)
	if err != nil {
		return nil, _oops.Wrapf(err, "parse APNS_P8")
	}
	host := _apnsProduction
	if os.Getenv("APNS_SANDBOX") == "1" {
		host = _apnsSandbox
	}
	return &apnsSender{
		client: &http.Client{Timeout: _apnsTimeout},
		host:   host,
		// Live Activity pushes go to the app's bundle id with this suffix; the
		// plain topic addresses the app itself and is rejected for this push type.
		topic:  topic + ".push-type.liveactivity",
		keyID:  keyID,
		teamID: teamID,
		key:    key,
	}, nil
}

// SendLiveActivity POSTs one update to one activity token. A 410 (the token is
// gone, i.e. the card ended without us hearing) is reported as ErrAPNSGone so
// the caller can drop the token instead of retrying it every hop.
func (s *apnsSender) SendLiveActivity(ctx context.Context, token string, payload []byte) error {
	jwt, err := s.providerToken()
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, s.host+"/3/device/"+token, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	request.Header.Set("authorization", "bearer "+jwt)
	request.Header.Set("apns-push-type", "liveactivity")
	request.Header.Set("apns-topic", s.topic)
	// 10 is "deliver immediately". A card refresh is only sent when the data
	// behind it moved, so there is nothing to coalesce by asking for less.
	request.Header.Set("apns-priority", "10")
	request.Header.Set("content-type", "application/json")

	response, err := s.client.Do(request)
	if err != nil {
		return err
	}
	defer func() { _ = response.Body.Close() }()
	switch response.StatusCode {
	case http.StatusOK:
		return nil
	case http.StatusGone:
		return ErrAPNSGone
	default:
		var body bytes.Buffer
		_, _ = body.ReadFrom(response.Body)
		return _oops.With("status_code", response.StatusCode).With("string", strings.TrimSpace(body.String())).Errorf("apns")
	}
}

// ErrAPNSGone is Apple's 410: this activity token no longer addresses a card.
var ErrAPNSGone = errors.New("apns: token no longer valid")

// providerToken returns the cached JWT, minting a new one once it ages past
// apnsTokenTTL.
func (s *apnsSender) providerToken() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	if s.nowFunc != nil {
		now = s.nowFunc()
	}
	if s.token != "" && now.Sub(s.tokenAge) < _apnsTokenTTL {
		return s.token, nil
	}
	token, err := signES256(s.key, map[string]string{"alg": "ES256", "kid": s.keyID}, map[string]any{
		"iss": s.teamID,
		"iat": now.Unix(),
	})
	if err != nil {
		return "", err
	}
	s.token, s.tokenAge = token, now
	return token, nil
}

// parseP8 reads Apple's PKCS#8 EC provider key. The env var may carry the PEM
// with real newlines or with the `\n` escapes a single-line env file forces.
func parseP8(value string) (*ecdsa.PrivateKey, error) {
	value = strings.ReplaceAll(value, `\n`, "\n")
	block, _ := pem.Decode([]byte(value))
	if block == nil {
		return nil, errors.New("no PEM block")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, _oops.With("parsed", parsed).Errorf("want an EC key")
	}
	return key, nil
}

// signES256 builds a JWS over the header and claims. ES256's signature is the
// raw r||s pair, each left-padded to the curve's 32 bytes — not the ASN.1 form
// ecdsa.SignASN1 produces, which Apple rejects.
func signES256(key *ecdsa.PrivateKey, header map[string]string, claims map[string]any) (string, error) {
	message := b64json(header) + "." + b64json(claims)
	sum := sha256.Sum256([]byte(message))
	r, sConcat, err := ecdsa.Sign(rand.Reader, key, sum[:])
	if err != nil {
		return "", err
	}
	out := make([]byte, 64)
	padInto(out[:32], r)
	padInto(out[32:], sConcat)
	return message + "." + base64.RawURLEncoding.EncodeToString(out), nil
}

func padInto(dst []byte, value *big.Int) {
	raw := value.Bytes()
	copy(dst[len(dst)-len(raw):], raw)
}

func b64json(v any) string {
	encoded, _ := json.Marshal(v)
	return base64.RawURLEncoding.EncodeToString(encoded)
}
