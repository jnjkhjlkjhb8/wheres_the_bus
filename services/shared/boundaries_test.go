package shared

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestEnvInt32Boundaries(t *testing.T) {
	for _, tc := range []struct {
		value string
		want  int32
	}{
		{"", 4}, {"bad", 4}, {"-1", 4}, {"2147483648", 4},
		{"0", 0}, {"1", 1}, {"2147483647", 2147483647},
	} {
		t.Setenv("QUALITY_INT32", tc.value)
		if got := EnvInt32("QUALITY_INT32", 4); got != tc.want {
			t.Errorf("value=%q got=%d want=%d", tc.value, got, tc.want)
		}
	}
}

func TestParseMMSSBoundaries(t *testing.T) {
	for _, tc := range []struct {
		value   string
		seconds int
		ok      bool
	}{
		{"0:00", 0, true}, {"1:00", 60, true}, {"0:59", 59, true}, {"123:45", 7425, true},
		{"", 0, false}, {"12", 0, false}, {"bad:01", 0, false}, {"01:bad", 0, false},
		{"-1:00", 0, false}, {"00:-1", 0, false}, {"0:60", 0, false}, {"1:2:3", 0, false},
	} {
		seconds, ok := ParseMMSS(tc.value)
		if seconds != tc.seconds || ok != tc.ok {
			t.Errorf("%q=%d,%v want=%d,%v", tc.value, seconds, ok, tc.seconds, tc.ok)
		}
	}
}

func TestTrtcLinePrefixBoundaries(t *testing.T) {
	for _, tc := range []struct{ station, prefix string }{{"BL12", "BL"}, {"BR0", "BR"}, {"A9", "A"}, {"12", ""}, {"BL", "BL"}, {"", ""}, {"松山1", "松山"}, {"B/12", "B/"}} {
		if got := TrtcLinePrefix(tc.station); got != tc.prefix {
			t.Errorf("%q=%q want=%q", tc.station, got, tc.prefix)
		}
	}
}

func TestConnectDBConfiguredPool(t *testing.T) {
	if os.Getenv("DATABASE_URL") == "" {
		t.Skip("DATABASE_URL not set")
	}
	t.Setenv("QUALITY_DB_MAX_CONNS", "4")
	t.Setenv("QUALITY_DB_MIN_CONNS", "1")
	t.Setenv("PG_SCHEMA", "public")
	t.Setenv("PG_STATEMENT_TIMEOUT", "1234")
	pool := ConnectDB("QUALITY_DB_MAX_CONNS", 3)
	defer pool.Close()
	config := pool.Config()
	if config.MaxConns != 4 || config.MinConns != 1 || config.MaxConnLifetime != 30*time.Minute || config.MaxConnIdleTime != 5*time.Minute {
		t.Fatalf("pool config max=%d min=%d lifetime=%v idle=%v", config.MaxConns, config.MinConns, config.MaxConnLifetime, config.MaxConnIdleTime)
	}
	var schema, timeout string
	if err := pool.QueryRow(context.Background(), "SELECT current_schema(), current_setting('statement_timeout')").Scan(&schema, &timeout); err != nil || schema != "public" || timeout != "1234ms" {
		t.Fatalf("session schema=%q timeout=%q error=%v", schema, timeout, err)
	}
}

func TestConnectDBRejectsMalformedURL(t *testing.T) {
	t.Setenv("DATABASE_URL", "://invalid")
	defer func() {
		if recover() == nil {
			t.Fatal("malformed database URL was accepted")
		}
	}()
	pool := ConnectDB("QUALITY_DB_MAX_CONNS", 2)
	pool.Close()
}

func TestTRTCResponseEmptyAndInvalidObjects(t *testing.T) {
	for _, body := range []string{"", `<string />`, `{}`, `{"TripId":""}`} {
		info, ok, err := decodeTRTCTrainInfo([]byte(body))
		if info != nil || ok || err != nil {
			t.Errorf("empty %q info=%v found=%v error=%v", body, info, ok, err)
		}
	}
	if info, ok, err := decodeTRTCTrainInfo([]byte(`{bad}`)); info != nil || ok || err == nil {
		t.Fatalf("malformed info=%v found=%v error=%v", info, ok, err)
	}
	for _, raw := range []string{"", "}", "{", "}{", strings.Repeat("plain", 3)} {
		if object, ok := extractJSONObject([]byte(raw)); object != nil || ok {
			t.Errorf("invalid object %q=%q,%v", raw, object, ok)
		}
	}
}
