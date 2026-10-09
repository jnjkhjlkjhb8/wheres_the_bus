package feedback

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/installid"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type fakeFeedbackStore struct {
	record    feedbackThreadRecord
	messageID string
	createdAt time.Time
	err       error
	calls     int
}

func (f *fakeFeedbackStore) OpenThread(_ context.Context, record feedbackThreadRecord, messageID string) (time.Time, error) {
	f.calls++
	if f.err != nil {
		return time.Time{}, f.err
	}
	f.record, f.messageID = record, messageID
	return f.createdAt, nil
}

type fakeInstallAuthorizer struct {
	installID string
	secret    string
	err       error
}

func (f fakeInstallAuthorizer) AuthorizeInstall(_ context.Context, installID string, secretHash []byte) (bool, error) {
	if f.err != nil {
		return false, f.err
	}
	want := sha256.Sum256([]byte(f.secret))
	return installID == f.installID && bytes.Equal(secretHash, want[:]), nil
}

type recordingNotifier struct{ notices []feedbackNotice }

func (r *recordingNotifier) Notify(notice feedbackNotice) { r.notices = append(r.notices, notice) }

func newTestFeedbackServer(store feedbackPersistence, notifier feedbackNotifier) *FeedbackServer {
	return &FeedbackServer{
		store:    store,
		devices:  fakeInstallAuthorizer{installID: "install-1", secret: _testInstallSecret},
		notifier: notifier,
	}
}

func validFeedbackRequest() *pb.PostFeedbackRequest {
	return &pb.PostFeedbackRequest{
		InstallId: "install-1",
		Category:  "eta",
		Body:      "  310 公車到站時間一直跳動\n說五分鐘又變十分鐘  ",
		Diagnostics: &pb.ReportDiagnostics{
			AppVersion: "1.4.2",
			Platform:   "ios",
			OsVersion:  "18.2",
			Screen:     "/bus/route/:subRouteUid",
			Locale:     "zh-TW",
		},
	}
}

func TestPostFeedbackStoresTrimmedReportAndNotifies(t *testing.T) {
	createdAt := time.Unix(1_780_000_000, 0)
	store := &fakeFeedbackStore{createdAt: createdAt}
	notifier := &recordingNotifier{}
	server := newTestFeedbackServer(store, notifier)

	receipt, err := server.PostFeedback(installationContext("install-1", _testInstallSecret), validFeedbackRequest())
	if err != nil {
		t.Fatalf("PostFeedback: %v", err)
	}
	if receipt.CreatedAtUnix != createdAt.Unix() {
		t.Fatalf("created_at = %d, want %d", receipt.CreatedAtUnix, createdAt.Unix())
	}
	if len(receipt.ThreadId) != 36 {
		t.Fatalf("thread_id = %q, want a UUID", receipt.ThreadId)
	}
	if store.record.ThreadID != receipt.ThreadId {
		t.Fatalf("stored thread %q, returned %q", store.record.ThreadID, receipt.ThreadId)
	}
	if store.messageID == store.record.ThreadID {
		t.Fatal("message reused the thread id; they must be distinct rows")
	}
	want := "310 公車到站時間一直跳動\n說五分鐘又變十分鐘"
	if store.record.Body != want {
		t.Fatalf("body = %q, want %q", store.record.Body, want)
	}
	if store.record.Diagnostics["locale"] != "zh-TW" || len(store.record.Diagnostics) != 5 {
		t.Fatalf("diagnostics = %v", store.record.Diagnostics)
	}
	if len(notifier.notices) != 1 || notifier.notices[0].ThreadID != receipt.ThreadId {
		t.Fatalf("notices = %v", notifier.notices)
	}
}

func TestPostFeedbackDropsEmptyDiagnosticsFields(t *testing.T) {
	store := &fakeFeedbackStore{}
	server := newTestFeedbackServer(store, &recordingNotifier{})
	request := validFeedbackRequest()
	request.Diagnostics = &pb.ReportDiagnostics{AppVersion: "1.4.2", Platform: "android"}

	if _, err := server.PostFeedback(installationContext("install-1", _testInstallSecret), request); err != nil {
		t.Fatalf("PostFeedback: %v", err)
	}
	if len(store.record.Diagnostics) != 2 {
		t.Fatalf("diagnostics = %v, want only the two filled fields", store.record.Diagnostics)
	}
	if _, ok := store.record.Diagnostics["locale"]; ok {
		t.Fatal("an unset field was stored as an empty string")
	}
}

func TestPostFeedbackQuotaIsResourceExhausted(t *testing.T) {
	store := &fakeFeedbackStore{err: errFeedbackQuota}
	notifier := &recordingNotifier{}
	server := newTestFeedbackServer(store, notifier)

	_, err := server.PostFeedback(installationContext("install-1", _testInstallSecret), validFeedbackRequest())
	if status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("code = %v, want %v", status.Code(err), codes.ResourceExhausted)
	}
	if len(notifier.notices) != 0 {
		t.Fatal("a rejected report was announced to ops")
	}
}

func TestPostFeedbackStoreFailureIsNotAnnounced(t *testing.T) {
	store := &fakeFeedbackStore{err: errors.New("connection refused")}
	notifier := &recordingNotifier{}
	server := newTestFeedbackServer(store, notifier)

	_, err := server.PostFeedback(installationContext("install-1", _testInstallSecret), validFeedbackRequest())
	if status.Code(err) != codes.Internal {
		t.Fatalf("code = %v, want %v", status.Code(err), codes.Internal)
	}
	if len(notifier.notices) != 0 {
		t.Fatal("a report that was never stored was announced to ops")
	}
}

func TestPostFeedbackRejectsUnauthorizedInstallBeforeWriting(t *testing.T) {
	store := &fakeFeedbackStore{}
	server := newTestFeedbackServer(store, &recordingNotifier{})

	_, err := server.PostFeedback(installationContext("install-1", _wrongInstallSecret), validFeedbackRequest())
	if status.Code(err) != codes.PermissionDenied {
		t.Fatalf("code = %v, want %v", status.Code(err), codes.PermissionDenied)
	}
	if store.calls != 0 {
		t.Fatal("the store was written before the caller was authorized")
	}
}

func TestPostFeedbackValidation(t *testing.T) {
	store := &fakeFeedbackStore{}
	server := newTestFeedbackServer(store, &recordingNotifier{})
	ctx := installationContext("install-1", _testInstallSecret)

	tests := []struct {
		name    string
		mutate  func(*pb.PostFeedbackRequest)
		wantErr codes.Code
	}{
		{"missing install id", func(r *pb.PostFeedbackRequest) { r.InstallId = "" }, codes.InvalidArgument},
		{"unknown category", func(r *pb.PostFeedbackRequest) { r.Category = "billing" }, codes.InvalidArgument},
		{"empty category", func(r *pb.PostFeedbackRequest) { r.Category = "" }, codes.InvalidArgument},
		{"blank body", func(r *pb.PostFeedbackRequest) { r.Body = "   \n  " }, codes.InvalidArgument},
		{"oversize body", func(r *pb.PostFeedbackRequest) {
			r.Body = strings.Repeat("報", _feedbackBodyLimit+1)
		}, codes.InvalidArgument},
		{"oversize diagnostics field", func(r *pb.PostFeedbackRequest) {
			r.Diagnostics.Screen = strings.Repeat("a", _feedbackFieldLimit+1)
		}, codes.InvalidArgument},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			request := validFeedbackRequest()
			tc.mutate(request)
			_, err := server.PostFeedback(ctx, request)
			if status.Code(err) != tc.wantErr {
				t.Fatalf("code = %v, want %v", status.Code(err), tc.wantErr)
			}
		})
	}
	if store.calls != 0 {
		t.Fatal("an invalid request reached the store")
	}
}

// A body at exactly the limit is valid: the check is a ceiling, not a fence.
func TestPostFeedbackAcceptsBodyAtLimit(t *testing.T) {
	store := &fakeFeedbackStore{}
	server := newTestFeedbackServer(store, &recordingNotifier{})
	request := validFeedbackRequest()
	request.Body = strings.Repeat("報", _feedbackBodyLimit)

	if _, err := server.PostFeedback(installationContext("install-1", _testInstallSecret), request); err != nil {
		t.Fatalf("PostFeedback: %v", err)
	}
}

func TestFeedbackWebhookContentQuotesEveryBodyLine(t *testing.T) {
	content := feedbackWebhookContent(feedbackNotice{
		ThreadID:    "a1b2c3d4-0000-4000-8000-000000000000",
		Category:    "route_data",
		Body:        "第一行\n第二行",
		Diagnostics: map[string]string{"app_version": "1.4.2", "platform": "ios", "locale": "zh-TW"},
	})
	if !strings.Contains(content, "`a1b2c3d4`") {
		t.Fatalf("content missing the case number: %q", content)
	}
	if !strings.Contains(content, "> 第一行\n> 第二行") {
		t.Fatalf("body lines were not all quoted: %q", content)
	}
	if !strings.HasSuffix(content, "1.4.2 · ios · zh-TW") {
		t.Fatalf("diagnostics summary = %q", content)
	}
}

func TestFeedbackWebhookContentStaysUnderDiscordLimit(t *testing.T) {
	content := feedbackWebhookContent(feedbackNotice{
		ThreadID: "a1b2c3d4-0000-4000-8000-000000000000",
		Category: "suggestion",
		Body:     strings.Repeat("報", _feedbackBodyLimit),
		Diagnostics: map[string]string{
			"app_version": "1.4.2", "platform": "ios", "os_version": "18.2",
			"locale": "zh-TW", "screen": "/bus/route/:subRouteUid",
		},
	})
	if runes := []rune(content); len(runes) > _discordContentLimit {
		t.Fatalf("content is %d runes, over Discord's %d limit", len(runes), _discordContentLimit)
	}
}

func TestWebhookNotifierPostsDisablingMentions(t *testing.T) {
	type payload struct {
		Content         string `json:"content"`
		AllowedMentions struct {
			Parse []string `json:"parse"`
		} `json:"allowed_mentions"`
	}
	received := make(chan payload, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Errorf("read body: %v", err)
			return
		}
		var decoded payload
		if err := json.Unmarshal(body, &decoded); err != nil {
			t.Errorf("decode body: %v", err)
			return
		}
		received <- decoded
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	notifier := &webhookNotifier{url: server.URL, client: server.Client()}
	err := notifier.post(context.Background(), feedbackNotice{
		ThreadID: "a1b2c3d4-0000-4000-8000-000000000000",
		Category: "crash",
		Body:     "@everyone App 開起來就閃退",
	})
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	got := <-received
	if got.AllowedMentions.Parse == nil || len(got.AllowedMentions.Parse) != 0 {
		t.Fatalf("allowed_mentions.parse = %v, want an empty list so rider text cannot ping", got.AllowedMentions.Parse)
	}
	if !strings.Contains(got.Content, "App 開起來就閃退") {
		t.Fatalf("content = %q", got.Content)
	}
}

func TestWebhookNotifierReportsFailureStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()

	notifier := &webhookNotifier{url: server.URL, client: server.Client()}
	if err := notifier.post(context.Background(), feedbackNotice{ThreadID: "t"}); err == nil {
		t.Fatal("a 429 from the webhook was reported as success")
	}
}

func TestNewFeedbackNotifierWithoutURLIsSilent(t *testing.T) {
	t.Setenv("FEEDBACK_WEBHOOK_URL", "")
	if _, ok := NewFeedbackNotifier().(silentNotifier); !ok {
		t.Fatal("an unset webhook URL must degrade to database-only, not configure a client")
	}
}

func TestShortThreadReference(t *testing.T) {
	if got := shortThreadReference("a1b2c3d4-0000-4000-8000-000000000000"); got != "a1b2c3d4" {
		t.Fatalf("reference = %q", got)
	}
	if got := shortThreadReference("nohyphenshere"); got != "nohyphenshere" {
		t.Fatalf("reference = %q", got)
	}
}

const (
	_testInstallSecret  = "0123456789abcdef0123456789abcdef"
	_wrongInstallSecret = "fedcba9876543210fedcba9876543210"
)

// installationContext carries the install credential the way the app does.
// The firebase tests keep their own copy: five lines beat a shared package.
func installationContext(installID, secret string) context.Context {
	return metadata.NewIncomingContext(context.Background(), metadata.Pairs(
		installid.MetadataKey, installID,
		installid.SecretMetadataKey, secret,
	))
}
