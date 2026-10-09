package feedback

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// errFeedbackQuota reports that the installation has already opened as many
// threads as the trailing window allows. It is a normal outcome of a hostile
// or looping client, not a fault, so it never reaches Sentry.
var errFeedbackQuota = errors.New("feedback quota exhausted")

// _feedbackQuota bounds one installation's threads inside _feedbackQuotaWindow.
// It is set where a determined rider reporting several genuine problems in one
// commute never reaches it, but a stuck client cannot fill the table.
const (
	_feedbackQuota       = 10
	_feedbackQuotaWindow = 24 * time.Hour
)

type feedbackThreadRecord struct {
	ThreadID    string
	InstallID   string
	Category    string
	Body        string
	Diagnostics map[string]string
}

// feedbackStore writes rider reports. It names the same pgx subset the device
// store uses — declared here rather than imported, so the feedback path takes
// no dependency on the device store beyond the credential check.
type feedbackDB interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
	Query(context.Context, string, ...any) (pgx.Rows, error)
	QueryRow(context.Context, string, ...any) pgx.Row
}

type feedbackStore struct{ db feedbackDB }

func NewFeedbackStore(db *pgxpool.Pool) *feedbackStore { return &feedbackStore{db: db} }

func (s *feedbackStore) OpenThread(ctx context.Context, record feedbackThreadRecord, messageID string) (time.Time, error) {
	diagnostics, err := json.Marshal(record.Diagnostics)
	if err != nil {
		return time.Time{}, err
	}
	var createdAt time.Time
	err = s.db.QueryRow(ctx, `
		WITH thread AS (
			INSERT INTO feedback_thread (id, install_id, category, diagnostics)
			SELECT $1, $2, $3, $4::jsonb
			WHERE (
				SELECT count(*) FROM feedback_thread
				WHERE install_id = $2
				  AND created_at > now() - ($5::double precision * interval '1 second')
			) < $6
			RETURNING id, created_at
		),
		message AS (
			INSERT INTO feedback_message (id, thread_id, author, body)
			SELECT $7, thread.id, 'user', $8 FROM thread
		)
		SELECT created_at FROM thread
	`,
		record.ThreadID, record.InstallID, record.Category, diagnostics,
		_feedbackQuotaWindow.Seconds(), _feedbackQuota,
		messageID, record.Body,
	).Scan(&createdAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, errFeedbackQuota
	}
	if err != nil {
		return time.Time{}, err
	}
	return createdAt, nil
}
