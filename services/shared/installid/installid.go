package installid

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"strings"

	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// Metadata keys the app carries on every device-scoped call.
const (
	MetadataKey       = "x-install-id"
	SecretMetadataKey = "x-install-secret"
)

type Authorizer interface {
	AuthorizeInstall(context.Context, string, []byte) (bool, error)
}

func SecretHash(ctx context.Context, installID string) ([]byte, error) {
	metadataInstallID, ok := CallerID(ctx)
	secrets := metadata.ValueFromIncomingContext(ctx, SecretMetadataKey)
	if !ok || metadataInstallID != installID || len(secrets) != 1 || !ValidText(secrets[0], 256) || len(secrets[0]) < 32 {
		zap.S().Warnw("credential rejected",
			"component", "firebase",
			"action", "installation_secret",
			"event", "missing_credential",
			"has_install_id", ok,
			"install_id_matches", metadataInstallID == installID,
			"secret_headers", len(secrets),
		)
		return nil, status.Error(codes.PermissionDenied, "valid installation credential required")
	}
	hash := sha256.Sum256([]byte(secrets[0]))
	return hash[:], nil
}

func CallerID(ctx context.Context) (string, bool) {
	values := metadata.ValueFromIncomingContext(ctx, MetadataKey)
	if len(values) != 1 || !ValidText(values[0], 128) {
		return "", false
	}
	return values[0], true
}

func ValidText(value string, limit int) bool {
	return value != "" && len(value) <= limit && strings.TrimSpace(value) == value
}

func NewUUIDv4() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	id[6] = id[6]&0x0f | 0x40
	id[8] = id[8]&0x3f | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", id[0:4], id[4:6], id[6:8], id[8:10], id[10:16]), nil
}

// Authorize checks the caller's install secret against the stored
// hash. It is shared by every device-scoped service, so one credential check
// covers them all rather than each re-deriving the same three failure modes.
func Authorize(ctx context.Context, devices Authorizer, installID string) error {
	secretHash, err := SecretHash(ctx, installID)
	if err != nil {
		return err
	}
	authorized, err := devices.AuthorizeInstall(ctx, installID, secretHash)
	if err != nil {
		zap.S().Errorw("store failed",
			"component", "firebase",
			"action", "authorize_install",
			"event", "store_failed",
			"install", installID,
			"err", err,
		)
		return status.Error(codes.Internal, "failed to verify installation credential")
	}
	if !authorized {
		return status.Error(codes.PermissionDenied, "installation credential does not match")
	}
	return nil
}
