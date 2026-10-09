package feedback

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestFeedbackStoreOpenThreadSQL(t *testing.T) {
	ctx := context.Background()
	mock, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer mock.Close()
	store := &feedbackStore{db: mock}
	createdAt := time.Unix(1_780_000_000, 0)

	record := feedbackThreadRecord{
		ThreadID:    "thread-1",
		InstallID:   "install-1",
		Category:    "eta",
		Body:        "到站時間跳動",
		Diagnostics: map[string]string{"platform": "ios", "app_version": "1.4.2"},
	}
	// json.Marshal sorts map keys, so the stored jsonb is byte-stable across
	// runs and can be asserted verbatim.
	diagnostics := []byte(`{"app_version":"1.4.2","platform":"ios"}`)

	mock.ExpectQuery("INSERT INTO feedback_thread.*INSERT INTO feedback_message").
		WithArgs("thread-1", "install-1", "eta", diagnostics,
			_feedbackQuotaWindow.Seconds(), _feedbackQuota, "message-1", "到站時間跳動").
		WillReturnRows(pgxmock.NewRows([]string{"created_at"}).AddRow(createdAt))

	got, err := store.OpenThread(ctx, record, "message-1")
	if err != nil {
		t.Fatalf("OpenThread: %v", err)
	}
	if !got.Equal(createdAt) {
		t.Fatalf("created_at = %v, want %v", got, createdAt)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

// A spent quota shows up as the insert selecting no row, which must surface as
// errFeedbackQuota rather than as a database fault: the caller maps the two to
// different gRPC codes, and only one of them is worth reporting.
func TestFeedbackStoreOpenThreadQuotaExhausted(t *testing.T) {
	mock, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer mock.Close()
	store := &feedbackStore{db: mock}

	mock.ExpectQuery("INSERT INTO feedback_thread").
		WithArgs(pgxmock.AnyArg(), pgxmock.AnyArg(), pgxmock.AnyArg(), pgxmock.AnyArg(),
			pgxmock.AnyArg(), pgxmock.AnyArg(), pgxmock.AnyArg(), pgxmock.AnyArg()).
		WillReturnError(pgx.ErrNoRows)

	_, err = store.OpenThread(context.Background(), feedbackThreadRecord{}, "message-1")
	if !errors.Is(err, errFeedbackQuota) {
		t.Fatalf("error = %v, want errFeedbackQuota", err)
	}
}
