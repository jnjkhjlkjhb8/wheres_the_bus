package feedback

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"go.uber.org/zap/zaptest/observer"
)

type feedbackContractTransport func(*http.Request) (*http.Response, error)

func (f feedbackContractTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAsyncWebhookFailureDiagnosticRetainsOriginalCauseAndThread(t *testing.T) {
	core, logs := observer.New(zap.DebugLevel)
	done := make(chan struct{}, 1)
	undo := zap.ReplaceGlobals(zap.New(zapcore.RegisterHooks(core, func(entry zapcore.Entry) error {
		if entry.Message == "post failed" {
			done <- struct{}{}
		}
		return nil
	})))
	t.Cleanup(undo)
	cause := errors.New("owned webhook transport unavailable")
	n := &webhookNotifier{url: "http://127.0.0.1/owned-test", client: &http.Client{Transport: feedbackContractTransport(func(*http.Request) (*http.Response, error) { return nil, cause })}}
	thread := "11111111-1111-4111-8111-111111111111"
	n.Notify(feedbackNotice{ThreadID: thread, Category: "eta", Body: "arrival report"})
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("failed webhook missing failure diagnostic")
	}
	for _, entry := range logs.FilterMessage("post failed").All() {
		if entry.ContextMap()["thread"] != thread || entry.ContextMap()["event"] != "post_failed" {
			continue
		}
		for _, field := range entry.Context {
			if err, ok := field.Interface.(error); field.Key == "err" && ok && errors.Is(err, cause) {
				return
			}
		}
	}
	t.Fatalf("failure lost thread/original error: %+v", logs.All())
}

func TestWebhookRejectsHTTP300AndAccepts299(t *testing.T) {
	for _, tc := range []struct {
		code    int
		failure bool
	}{{299, false}, {300, true}} {
		t.Run(fmt.Sprint(tc.code), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(tc.code) }))
			defer server.Close()
			n := &webhookNotifier{url: server.URL, client: server.Client()}
			err := n.post(context.Background(), feedbackNotice{ThreadID: "11111111-1111-4111-8111-111111111111", Category: "eta", Body: "report"})
			if (err != nil) != tc.failure {
				t.Fatalf("HTTP%d result=%v", tc.code, err)
			}
		})
	}
}

func feedbackPostedContent(t *testing.T, notice feedbackNotice) string {
	t.Helper()
	var content string
	n := &webhookNotifier{url: "http://127.0.0.1/owned-test", client: &http.Client{Transport: feedbackContractTransport(func(r *http.Request) (*http.Response, error) {
		var payload struct {
			Content         string `json:"content"`
			AllowedMentions struct {
				Parse []string `json:"parse"`
			} `json:"allowed_mentions"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			return nil, err
		}
		if payload.AllowedMentions.Parse == nil || len(payload.AllowedMentions.Parse) != 0 {
			return nil, errors.New("mention suppression missing")
		}
		content = payload.Content
		return &http.Response{StatusCode: http.StatusNoContent, Status: "204 No Content", Header: make(http.Header), Body: io.NopCloser(strings.NewReader("")), Request: r}, nil
	})}}
	if err := n.post(context.Background(), notice); err != nil {
		t.Fatal(err)
	}
	return content
}

func TestWebhookRetainsEveryRuneOfBodyAtNoticeCeiling(t *testing.T) {
	body := strings.Repeat("報", 1499) + "尾"
	notice := feedbackNotice{ThreadID: "11111111-1111-4111-8111-111111111111", Category: "eta", Body: body}
	want := "**新回報** `eta` · `11111111`\n> " + body + "\n"
	if got := feedbackPostedContent(t, notice); got != want {
		t.Fatalf("1500-rune report payload changed: got runes=%d, tail=%q", utf8.RuneCountInString(got), got[len(got)-12:])
	}
}

func TestWebhookContentCeilingPreservesPrefixAndExactBoundary(t *testing.T) {
	body := strings.Repeat("報", 1500)
	headerAndBody := "**新回報** `eta` · `11111111`\n> " + body + "\n"
	for _, extra := range []int{0, 1} {
		t.Run(fmt.Sprintf("over-by-%d", extra), func(t *testing.T) {
			screenRunes := 2000 + extra - utf8.RuneCountInString(headerAndBody) - 4*100 - 4*3
			if screenRunes < 1 || screenRunes > 128 {
				t.Fatalf("invalid diagnostics fixture length=%d", screenRunes)
			}
			diagnostics := map[string]string{"app_version": strings.Repeat("版", 100), "platform": strings.Repeat("台", 100), "os_version": strings.Repeat("系", 100), "locale": strings.Repeat("語", 100), "screen": strings.Repeat("畫", screenRunes)}
			summary := strings.Join([]string{diagnostics["app_version"], diagnostics["platform"], diagnostics["os_version"], diagnostics["locale"], diagnostics["screen"]}, " · ")
			full := headerAndBody + summary
			want := full
			if extra != 0 {
				want = string([]rune(full)[:1999]) + "…"
			}
			got := feedbackPostedContent(t, feedbackNotice{ThreadID: "11111111-1111-4111-8111-111111111111", Category: "eta", Body: body, Diagnostics: diagnostics})
			if got != want || utf8.RuneCountInString(got) != 2000 {
				t.Fatalf("ceiling payload changed, full=%d actual=%d expected=%d", utf8.RuneCountInString(full), utf8.RuneCountInString(got), utf8.RuneCountInString(want))
			}
		})
	}
}

func feedbackContractPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL required")
	}
	admin, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	schema := fmt.Sprintf("quality_feedback_contract_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{schema}.Sanitize()
	if _, err := admin.Exec(context.Background(), "CREATE SCHEMA "+quoted); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+quoted+" CASCADE"); admin.Close() })
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.RuntimeParams["search_path"] = schema
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	if _, err := pool.Exec(context.Background(), `CREATE TABLE feedback_thread (
 id uuid PRIMARY KEY, install_id text NOT NULL CHECK(install_id<>''),
 category text NOT NULL CHECK(category IN ('route_data','eta','crash','suggestion')),
 diagnostics jsonb NOT NULL DEFAULT '{}'::jsonb,
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','closed')),
 created_at timestamptz NOT NULL DEFAULT now());
 CREATE TABLE feedback_message(id uuid PRIMARY KEY,thread_id uuid NOT NULL REFERENCES feedback_thread(id) ON DELETE CASCADE,
 author text NOT NULL CHECK(author IN ('user','ops')),body text NOT NULL CHECK(body<>''),created_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		t.Fatal(err)
	}
	return pool
}

func TestFeedbackQuotaUsesTrailingTwentyFourHourWindow(t *testing.T) {
	for _, tc := range []struct {
		ageHours int
		quota    bool
	}{{23, true}, {25, false}} {
		t.Run(fmt.Sprint(tc.ageHours), func(t *testing.T) {
			db := feedbackContractPool(t)
			ctx := context.Background()
			for i := 1; i <= 10; i++ {
				id := fmt.Sprintf("00000000-0000-4000-8000-%012d", i)
				if _, err := db.Exec(ctx, `INSERT INTO feedback_thread(id,install_id,category,created_at) VALUES($1,'install-window','eta',NOW()-make_interval(hours=>$2))`, id, tc.ageHours); err != nil {
					t.Fatal(err)
				}
			}
			record := feedbackThreadRecord{ThreadID: "11111111-1111-4111-8111-111111111111", InstallID: "install-window", Category: "eta", Body: "new report", Diagnostics: map[string]string{"locale": "zh-TW"}}
			created, err := NewFeedbackStore(db).OpenThread(ctx, record, "22222222-2222-4222-8222-222222222222")
			if errors.Is(err, errFeedbackQuota) != tc.quota || (err != nil && !errors.Is(err, errFeedbackQuota)) {
				t.Fatalf("age=%d quota=%t err=%v", tc.ageHours, tc.quota, err)
			}
			var threads, messages int
			if err := db.QueryRow(ctx, `SELECT (SELECT count(*) FROM feedback_thread),(SELECT count(*) FROM feedback_message)`).Scan(&threads, &messages); err != nil {
				t.Fatal(err)
			}
			wantThreads, wantMessages := 11, 1
			if tc.quota {
				wantThreads, wantMessages = 10, 0
			}
			if threads != wantThreads || messages != wantMessages || (tc.quota && !created.IsZero()) || (!tc.quota && created.IsZero()) {
				t.Fatalf("quota publication threads=%d messages=%d created=%v", threads, messages, created)
			}
		})
	}
}

func TestMalformedWebhookURLFailsBeforeAnyTransport(t *testing.T) {
	called := false
	n := &webhookNotifier{url: "://broken", client: &http.Client{Transport: feedbackContractTransport(func(*http.Request) (*http.Response, error) {
		called = true
		return nil, errors.New("unexpected transport")
	})}}
	err := n.post(context.Background(), feedbackNotice{ThreadID: "11111111-1111-4111-8111-111111111111", Category: "eta", Body: "report"})
	var parseError *url.Error
	if !errors.As(err, &parseError) || called {
		t.Fatalf("URL error=%v, transport called=%t", err, called)
	}
}
