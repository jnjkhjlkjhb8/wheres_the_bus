package notify

import (
	"context"
	"encoding/json"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// notificationDB is the minimal pgx surface Store needs, so it can
// be backed by a pool or a test double.
type notificationDB interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

// Store reads push subscriptions and arrival reminders and mutates
// reminder state (claim/fire/release, token invalidation) in PostgreSQL.
type Store struct{ db notificationDB }

// deviceToken is a single device's FCM token.
type deviceToken struct{ token string }

// arrivalReminder is a pending arrival reminder joined to its device token.
// leadMinutes is how far ahead of arrival the user asked to be notified.
type arrivalReminder struct {
	id, token, routeType, routeKey, stopKey, direction string
	leadMinutes                                        int
	plate                                              string
	// alightEvent is "lead"/"alight" for a 下車提醒 row, "" for a legacy
	// arrival reminder. It decides whether the push vibrates or banners.
	alightEvent string
}

func (s Store) subscribedTokens(ctx context.Context, routeType, routeKey string) ([]deviceToken, error) {
	rows, err := s.db.Query(ctx, `SELECT d.fcm_token FROM firebase_route_subscription s JOIN firebase_device d ON d.install_id=s.install_id WHERE s.route_type=$1 AND ($2='' OR s.route_key=$2) AND d.push_enabled AND d.fcm_token<>''`, routeType, routeKey)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []deviceToken
	for rows.Next() {
		var v deviceToken
		if err := rows.Scan(&v.token); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (s Store) activeRemindersForArrivals(ctx context.Context, events []ArrivalEvent, now time.Time) ([]arrivalMatch, error) {
	if len(events) == 0 {
		return nil, nil
	}
	payload, err := json.Marshal(events)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.Query(ctx, `WITH arrivals AS (
		SELECT * FROM jsonb_to_recordset($1::jsonb) AS a(
			route_type text, route_key text, stop_key text, direction text,
			eta_seconds integer, arriving_plate text
		)
	)
	SELECT r.reminder_id,d.fcm_token,r.route_type,r.route_key,r.stop_key,r.direction,r.lead_minutes,r.plate,r.alight_event,
		a.route_type,a.route_key,a.stop_key,a.direction,a.eta_seconds,a.arriving_plate
	FROM arrivals a
	JOIN firebase_arrival_reminder r
		ON r.route_type=a.route_type AND r.route_key=a.route_key
		AND r.stop_key=a.stop_key AND r.direction=a.direction
	JOIN firebase_device d ON d.install_id=r.install_id
	WHERE a.eta_seconds>=0 AND a.eta_seconds<=r.lead_minutes*60
		AND (r.plate='' OR r.plate=a.arriving_plate)
		AND (r.status='pending' OR (r.status='sending' AND (r.claimed_at IS NULL OR r.claimed_at<=$3)))
		AND r.expires_at>$2
		AND d.push_enabled AND d.fcm_token<>''`, string(payload), now, now.Add(-ReminderClaimTimeout))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var matches []arrivalMatch
	for rows.Next() {
		var match arrivalMatch
		if err := rows.Scan(
			&match.reminder.id, &match.reminder.token, &match.reminder.routeType, &match.reminder.routeKey,
			&match.reminder.stopKey, &match.reminder.direction, &match.reminder.leadMinutes, &match.reminder.plate,
			&match.reminder.alightEvent,
			&match.arrival.RouteType, &match.arrival.RouteKey, &match.arrival.StopKey, &match.arrival.Direction,
			&match.arrival.ETASeconds, &match.arrival.ArrivingPlate,
		); err != nil {
			return nil, err
		}
		matches = append(matches, match)
	}
	return matches, rows.Err()
}

func (s Store) dueScheduledReminders(ctx context.Context, now time.Time) ([]arrivalReminder, error) {
	rows, err := s.db.Query(ctx, `SELECT r.reminder_id,d.fcm_token,r.route_type,r.route_key,r.stop_key,r.direction,r.lead_minutes,r.alight_event FROM firebase_arrival_reminder r JOIN firebase_device d ON d.install_id=r.install_id WHERE (r.status='pending' OR (r.status='sending' AND (r.claimed_at IS NULL OR r.claimed_at<=$2))) AND r.fire_at IS NOT NULL AND r.fire_at<=$1 AND r.expires_at>$1 AND d.push_enabled AND d.fcm_token<>''`, now, now.Add(-ReminderClaimTimeout))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []arrivalReminder
	for rows.Next() {
		var v arrivalReminder
		if err := rows.Scan(&v.id, &v.token, &v.routeType, &v.routeKey, &v.stopKey, &v.direction, &v.leadMinutes, &v.alightEvent); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

type MrtTrackReminder struct {
	ID        string
	Token     string
	LeadStops int
}

func (s Store) ActiveMrtTracks(ctx context.Context, now time.Time) ([]MrtTrackReminder, error) {
	rows, err := s.db.Query(ctx, `SELECT r.reminder_id, COALESCE(d.fcm_token, ''), r.lead_minutes
		FROM firebase_arrival_reminder r
		LEFT JOIN firebase_device d ON d.install_id = r.install_id AND d.push_enabled AND d.fcm_token <> ''
		WHERE r.route_type = 'mrt' AND r.status IN ('pending', 'sending', 'fired') AND r.expires_at > $1`, now)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []MrtTrackReminder
	for rows.Next() {
		var v MrtTrackReminder
		if err := rows.Scan(&v.ID, &v.Token, &v.LeadStops); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (s Store) ExpireMrtTrack(ctx context.Context, id string) error {
	_, err := s.db.Exec(ctx, `UPDATE firebase_arrival_reminder SET status = 'expired', updated_at = NOW()
		WHERE reminder_id = $1 AND status = 'pending'`, id)
	return err
}

// rowsChanged reports whether a conditional UPDATE affected exactly its one
// target row, which is how the claim/fire/release state transitions detect
// whether they actually won the race. The input error is passed through.
func rowsChanged(tag pgconn.CommandTag, err error) (bool, error) { return tag.RowsAffected() == 1, err }

const ReminderClaimTimeout = 5 * time.Minute

func (s Store) claim(ctx context.Context, id string, now time.Time) (bool, error) {
	tag, err := s.db.Exec(ctx, `UPDATE firebase_arrival_reminder SET status='sending',claimed_at=$2,updated_at=NOW() WHERE reminder_id=$1 AND expires_at>$2 AND (status='pending' OR (status='sending' AND (claimed_at IS NULL OR claimed_at<=$3)))`, id, now, now.Add(-ReminderClaimTimeout))
	return rowsChanged(tag, err)
}

// release returns a claimed ('sending') reminder to 'pending' so it can be
// retried, used when a send fails after the claim was taken. claimed_at is
// cleared so it only ever describes the current 'sending' claim.
func (s Store) release(ctx context.Context, id string) (bool, error) {
	tag, err := s.db.Exec(ctx, `UPDATE firebase_arrival_reminder SET status='pending',claimed_at=NULL,updated_at=NOW() WHERE reminder_id=$1 AND status='sending'`, id)
	return rowsChanged(tag, err)
}

// fired marks a claimed reminder 'fired' after a successful send, stamping
// fired_at, so it is not sent again.
func (s Store) fired(ctx context.Context, id string, now time.Time) (bool, error) {
	tag, err := s.db.Exec(ctx, `UPDATE firebase_arrival_reminder SET status='fired',fired_at=$2,updated_at=NOW() WHERE reminder_id=$1 AND status='sending'`, id, now)
	return rowsChanged(tag, err)
}

// invalidate clears a device's FCM token and disables push for it, called when
// FCM reports the token is unregistered so dead tokens stop being targeted.
func (s Store) invalidate(ctx context.Context, token string) error {
	_, err := s.db.Exec(ctx, `UPDATE firebase_device SET fcm_token='',push_enabled=FALSE,updated_at=NOW() WHERE fcm_token=$1`, token)
	return err
}

// NewStore wraps a database handle in the notification storage used by the
// dispatcher.
func NewStore(db notificationDB) Store { return Store{db: db} }

// PruneReminders bounds the reminder table after terminal rows have served
// their operational purpose. Pending rows are retained until expiry.
func (s Store) PruneReminders(ctx context.Context, before time.Time) error {
	_, err := s.db.Exec(ctx, `DELETE FROM firebase_arrival_reminder WHERE status IN ('cancelled','fired','expired') AND updated_at < $1`, before)
	return err
}
