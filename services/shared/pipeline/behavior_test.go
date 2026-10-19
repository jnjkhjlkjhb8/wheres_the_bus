package pipeline

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/samber/oops"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

func decoder(body string) *json.Decoder { return json.NewDecoder(strings.NewReader(body)) }

func TestDecodeLoadArrayValidationAndMalformedPayloads(t *testing.T) {
	var indexes []int
	got, err := DecodeLoadArray(decoder(`[4,8]`), "probe", func(i, value int) error {
		indexes = append(indexes, i)
		if value != (i+1)*4 {
			return errors.New("wrong row")
		}
		return nil
	})
	if err != nil || !reflect.DeepEqual(got, []int{4, 8}) || !reflect.DeepEqual(indexes, []int{0, 1}) {
		t.Fatalf("rows=%v indexes=%v error=%v", got, indexes, err)
	}
	for _, body := range []string{"", `{}`, `["wrong type"]`, `[1`, `[1}`, `[] true`, `[] broken`} {
		rows, err := DecodeLoadArray[int](decoder(body), "probe", nil)
		if err == nil || rows != nil || !errMentions(err, "probe") {
			t.Errorf("payload %q: rows=%v error=%v", body, rows, err)
		}
	}
	rows, err := DecodeLoadArray[int](decoder(`[]`), "probe", nil)
	if err != nil || rows == nil || len(rows) != 0 {
		t.Fatalf("empty array rows=%v error=%v", rows, err)
	}
	invalid := errors.New("invalid row")
	rows, err = DecodeLoadArray(decoder(`[1,2]`), "probe", func(index, _ int) error {
		if index == 1 {
			return invalid
		}
		return nil
	})
	var structured oops.OopsError
	if rows != nil || !errors.Is(err, invalid) || !errors.As(err, &structured) || structured.Context()["index"] != 1 {
		t.Fatalf("rejected row: rows=%v error=%v", rows, err)
	}
}

func TestDecodeLiveItemsStreamsAndRejectsTrailers(t *testing.T) {
	var got []int
	if err := DecodeLiveItems(decoder(`[1,2]`), func(value int) error { got = append(got, value); return nil }); err != nil || !reflect.DeepEqual(got, []int{1, 2}) {
		t.Fatalf("items=%v error=%v", got, err)
	}
	for _, body := range []string{"", `{}`, `["wrong type"]`, `[1`, `[1}`, `[] true`, `[] broken`} {
		if err := DecodeLiveItems(decoder(body), func(int) error { return nil }); err == nil {
			t.Errorf("accepted malformed payload %q", body)
		}
	}
	want := errors.New("sink failed")
	calls := 0
	err := DecodeLiveItems(decoder(`[1,2]`), func(int) error { calls++; return want })
	if !errors.Is(err, want) || calls != 1 {
		t.Fatalf("consumer failure error=%v calls=%d", err, calls)
	}
	err = DecodeLiveItems(decoder(`{"message":"`+strings.Repeat("x", 400)+`"}`), func(int) error { return nil })
	if err == nil || !errMentions(err, "…") || errMentions(err, strings.Repeat("x", 300)) {
		t.Fatalf("unbounded envelope diagnostic: %v", err)
	}
}

func TestAppendUniqueLoadRow(t *testing.T) {
	var rows [][]any
	seen := make(map[string][]any)
	for _, row := range [][]any{{"a", 1}, {"a", 1}} {
		if err := AppendUniqueLoadRow(&rows, seen, "a", "probe", row); err != nil {
			t.Fatal(err)
		}
	}
	if len(rows) != 1 || !reflect.DeepEqual(rows[0], []any{"a", 1}) {
		t.Fatalf("deduplicated rows=%v", rows)
	}
	if err := AppendUniqueLoadRow(&rows, seen, "a", "probe", []any{"a", 2}); err == nil || !errMentions(err, "probe") {
		t.Fatalf("conflicting duplicate error=%v", err)
	}
	if len(rows) != 1 || !reflect.DeepEqual(seen["a"], []any{"a", 1}) {
		t.Fatalf("conflict replaced original row: rows=%v seen=%v", rows, seen)
	}
}

func TestServiceDayMasks(t *testing.T) {
	for bits := range 256 {
		var days [8]bool
		var flags [7]uint8
		for i := range days {
			days[i] = bits&(1<<i) != 0
			if i < len(flags) && days[i] {
				flags[i] = 1
			}
		}
		if got := Mask(days[0], days[1], days[2], days[3], days[4], days[5], days[6], days[7]); got != uint8(bits) {
			t.Fatalf("Mask bits=%d got=%d", bits, got)
		}
		if got := Mask2(flags[0], flags[1], flags[2], flags[3], flags[4], flags[5], flags[6]); got != uint8(bits&127) {
			t.Fatalf("Mask2 bits=%d got=%d", bits, got)
		}
	}
	if got := Mask(true, false, false, false, false, false, false); got != 1 {
		t.Fatalf("Mask without holiday = %d", got)
	}
	if got := Mask2(2, 255, 0, 0, 0, 0, 0); got != 0 {
		t.Fatalf("unexpected TDX flags became service days: %d", got)
	}
}

func TestPositionAndClockBoundaries(t *testing.T) {
	for _, tc := range []struct {
		lon, lat float64
		want     bool
	}{
		{180, 90, true}, {-180, -90, true}, {0, 1, true}, {1, 0, true}, {0, 0, false},
		{180.1, 1, false}, {-180.1, 1, false}, {1, 90.1, false}, {1, -90.1, false},
		{math.NaN(), 1, false}, {1, math.NaN(), false},
		{math.Inf(1), 1, false}, {1, math.Inf(-1), false},
	} {
		if got := ValidPosition(tc.lon, tc.lat); got != tc.want {
			t.Errorf("position(%v,%v)=%v want=%v", tc.lon, tc.lat, got, tc.want)
		}
	}
	for _, tc := range []struct {
		clock string
		want  bool
	}{
		{"00:00", true}, {"23:59", true}, {"24:00", false}, {"12:60", false}, {"12:00:00", false}, {"", false},
	} {
		if got := ValidClock(tc.clock); got != tc.want {
			t.Errorf("clock %q=%v", tc.clock, got)
		}
	}
}

func TestTimeoutAndDailyRetry(t *testing.T) {
	want := errors.New("job failed")
	if err := RunWithTimeout(context.Background(), time.Hour, func(ctx context.Context) error {
		if _, bounded := ctx.Deadline(); !bounded {
			t.Fatal("job was unbounded")
		}
		return want
	}); !errors.Is(err, want) {
		t.Fatalf("job error=%v", err)
	}
	if err := RunWithTimeout(context.Background(), 0, func(context.Context) error { return nil }); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("late success error=%v", err)
	}
	if err := RunWithTimeout(context.Background(), time.Hour, func(context.Context) error { return nil }); err != nil {
		t.Fatal(err)
	}
	called := false
	WithTimeout(time.Hour, func(ctx context.Context) {
		called = true
		if ctx.Err() != nil {
			t.Fatal(ctx.Err())
		}
	})
	if !called {
		t.Fatal("job did not run")
	}
	attempts := 0
	err := RunDailyWithRetry(context.Background(), time.Hour, time.Millisecond, func(context.Context) error {
		attempts++
		if attempts < 3 {
			return want
		}
		return nil
	})
	if err != nil || attempts != 3 {
		t.Fatalf("retry attempts=%d error=%v", attempts, err)
	}
	attempts = 0
	err = RunDailyWithRetry(context.Background(), time.Hour, time.Millisecond, func(context.Context) error { attempts++; return want })
	if !errors.Is(err, want) || attempts != 3 {
		t.Fatalf("exhausted attempts=%d error=%v", attempts, err)
	}
	core, logs := observer.New(zap.ErrorLevel)
	undo := zap.ReplaceGlobals(zap.New(core))
	defer undo()
	RunDaily("quality", time.Hour, func(context.Context) error { return nil })
	if logs.Len() != 0 {
		t.Fatalf("successful daily job logged a failure: %v", logs.All())
	}
}

func TestErrorWithoutPreservesOtherCauses(t *testing.T) {
	target, keep := errors.New("closed"), errors.New("transport")
	for _, err := range []error{target, fmt.Errorf("wrapped: %w", target), errors.Join(target, fmt.Errorf("nested: %w", target))} {
		if got := errorWithout(err, target); got != nil {
			t.Errorf("sentinel survives: %v", got)
		}
	}
	if got := errorWithout(nil, target); got != nil {
		t.Fatal(got)
	}
	if got := errorWithout(fmt.Errorf("wrapper: %w", keep), target); !errors.Is(got, keep) || !strings.Contains(got.Error(), "wrapper") {
		t.Fatalf("unrelated wrapper=%v", got)
	}
	got := errorWithout(fmt.Errorf("wrapper: %w", errors.Join(target, keep)), target)
	if !errors.Is(got, keep) || errors.Is(got, target) {
		t.Fatalf("joined filtering=%v", got)
	}
}

func TestSQLStringLiteralAndQuarantineReport(t *testing.T) {
	if got := SQLStringLiteral("O'Hare"); got != "'O''Hare'" {
		t.Fatal(got)
	}
	core, logs := observer.New(zap.WarnLevel)
	undo := zap.ReplaceGlobals(zap.New(core))
	defer undo()
	q := NewQuarantine("bus", "Taipei")
	q.Consider("shape", 2)
	q.Consider("shape", 2)
	q.Drop("shape", "missing", "first sample")
	q.Drop("unseen", "empty", "sample")
	q.Report()
	entries := logs.All()
	if len(entries) != 2 {
		t.Fatalf("report entries=%v", entries)
	}
	fields := entries[1].ContextMap()
	if fields["reason"] != "missing" || fields["ratio"] != 0.25 || fields["of"] != int64(4) || fields["first"] != "first_sample" {
		t.Fatalf("report fields=%v", fields)
	}
}
