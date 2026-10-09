package firebase

import (
	"context"
	"crypto/subtle"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

var errFirebaseNotFound = errors.New("firebase record not found")
var ErrReminderLimitReached = errors.New("arrival reminder limit reached")
var ErrReminderDuplicate = errors.New("arrival reminder already exists")

const ReminderPending = "pending"

type FirebaseArrivalReminder struct {
	ReminderID  string
	InstallID   string
	RouteType   string
	RouteKey    string
	StopKey     string
	Direction   string
	LeadMinutes int32
	FireAt      *time.Time
	ExpiresAt   time.Time
	Status      string
	Token       string
	Plate       string
	AlightEvent string
}

type firebaseDB interface {
	Begin(context.Context) (pgx.Tx, error)
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
	Query(context.Context, string, ...any) (pgx.Rows, error)
	QueryRow(context.Context, string, ...any) pgx.Row
}

type firebaseStore struct{ db firebaseDB }

func NewFirebaseStore(db *pgxpool.Pool) *firebaseStore { return &firebaseStore{db: db} }

func (s *firebaseStore) UpsertDevice(ctx context.Context, identity *pb.DeviceIdentity, prefs *pb.DevicePrefs, secretHash []byte) (*pb.DeviceState, bool, error) {
	result, err := s.db.Exec(ctx, `
		INSERT INTO firebase_device
			(install_id, fcm_token, platform, app_version, push_enabled, install_secret_hash)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (install_id) DO UPDATE SET
			fcm_token = EXCLUDED.fcm_token,
			platform = EXCLUDED.platform,
			app_version = EXCLUDED.app_version,
			push_enabled = EXCLUDED.push_enabled, updated_at = NOW()
		WHERE firebase_device.install_secret_hash = EXCLUDED.install_secret_hash`,
		identity.InstallId, identity.FcmToken, identity.Platform, identity.AppVersion,
		prefs.PushEnabled, secretHash,
	)
	if err != nil {
		return nil, false, err
	}
	state := &pb.DeviceState{
		Identity: &pb.DeviceIdentity{InstallId: identity.InstallId, Platform: identity.Platform, AppVersion: identity.AppVersion},
		Prefs:    prefs,
	}
	return state, result.RowsAffected() == 1, nil
}

// AuthorizeInstall reports whether secretHash matches the hash stored for the
// install. An unknown install returns (false, nil), not an error. The comparison
// is constant-time to avoid leaking the hash through timing.
func (s *firebaseStore) AuthorizeInstall(ctx context.Context, installID string, secretHash []byte) (bool, error) {
	var storedHash []byte
	err := s.db.QueryRow(ctx, `SELECT install_secret_hash FROM firebase_device WHERE install_id = $1`, installID).Scan(&storedHash)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return len(storedHash) == len(secretHash) && subtle.ConstantTimeCompare(storedHash, secretHash) == 1, nil
}

func (s *firebaseStore) ReplaceRouteSubscriptions(ctx context.Context, installID string, subscriptions []*pb.RouteSubscription) error {
	types := make([]string, len(subscriptions))
	keys := make([]string, len(subscriptions))
	for i, subscription := range subscriptions {
		types[i], keys[i] = subscription.GetRouteType(), subscription.GetRouteKey()
	}
	_, err := s.db.Exec(ctx, `
		WITH desired AS (
			SELECT t AS route_type, k AS route_key
			FROM unnest($2::text[], $3::text[]) AS pair(t, k)
		), removed AS (
			DELETE FROM firebase_route_subscription s
			WHERE s.install_id = $1
			  AND NOT EXISTS (
			      SELECT 1 FROM desired d
			      WHERE d.route_type = s.route_type AND d.route_key = s.route_key)
		)
		INSERT INTO firebase_route_subscription (install_id, route_type, route_key)
		SELECT $1, route_type, route_key FROM desired
		ON CONFLICT (install_id, route_type, route_key) DO NOTHING`, installID, types, keys)
	return err
}

// CreateArrivalReminder inserts a reminder row. Token is not persisted here; it
// is joined from the device row when reminders are later listed for dispatch.
func (s *firebaseStore) CreateArrivalReminder(ctx context.Context, reminder FirebaseArrivalReminder) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`, reminder.InstallID); err != nil {
		return err
	}
	result, err := tx.Exec(ctx, `INSERT INTO firebase_arrival_reminder
			(reminder_id, install_id, route_type, route_key, stop_key, direction, lead_minutes, fire_at, expires_at, status, plate, alight_event)
			SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12
			WHERE (SELECT count(*) FROM firebase_arrival_reminder WHERE install_id=$2 AND status IN ('pending','sending') AND expires_at > NOW()) < 50
			ON CONFLICT DO NOTHING`,
		reminder.ReminderID, reminder.InstallID, reminder.RouteType, reminder.RouteKey, reminder.StopKey, reminder.Direction,
		reminder.LeadMinutes, reminder.FireAt, reminder.ExpiresAt, reminder.Status, reminder.Plate, reminder.AlightEvent)
	if err != nil {
		return err
	}
	if result.RowsAffected() == 0 {
		var active int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM firebase_arrival_reminder WHERE install_id=$1 AND status IN ('pending','sending') AND expires_at > NOW()`, reminder.InstallID).Scan(&active); err != nil {
			return err
		}
		if active >= 50 {
			return ErrReminderLimitReached
		}
		return ErrReminderDuplicate
	}
	return tx.Commit(ctx)
}

// CancelArrivalReminder marks a caller-owned pending reminder as cancelled. The
// returned bool is true only when exactly one pending row was updated, so an
// already-fired, already-cancelled, or foreign reminder yields false.
func (s *firebaseStore) CancelArrivalReminder(ctx context.Context, reminderID, installID string) (bool, error) {
	result, err := s.db.Exec(ctx, `
		UPDATE firebase_arrival_reminder
		SET status = 'cancelled', updated_at = NOW()
		WHERE reminder_id = $1 AND install_id = $2 AND status = 'pending'`, reminderID, installID)
	return result.RowsAffected() == 1, err
}

func (s *firebaseStore) CancelArrivalReminderByID(ctx context.Context, reminderID string) (bool, error) {
	result, err := s.db.Exec(ctx, `
		UPDATE firebase_arrival_reminder
		SET status = 'cancelled', updated_at = NOW()
		WHERE reminder_id = $1 AND status = 'pending'`, reminderID)
	return result.RowsAffected() == 1, err
}

// ListDeviceState loads a device's platform, version, and preference flags. It
// returns errFirebaseNotFound (which the service layer maps to gRPC NotFound)
// when no row exists.
func (s *firebaseStore) ListDeviceState(ctx context.Context, installID string) (*pb.DeviceState, error) {
	state := &pb.DeviceState{Identity: &pb.DeviceIdentity{InstallId: installID}, Prefs: &pb.DevicePrefs{}}
	err := s.db.QueryRow(ctx, `
		SELECT platform, app_version, push_enabled
		FROM firebase_device WHERE install_id = $1`, installID).Scan(
		&state.Identity.Platform, &state.Identity.AppVersion, &state.Prefs.PushEnabled,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errFirebaseNotFound
	}
	return state, err
}
