package main

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/pashagolub/pgxmock/v4"
)

func TestHourlyChangedMarkerPreservesLastSuccessWhenSourceReadFails(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery("SELECT partition_value, last_modified").WillReturnRows(
		db.NewRows([]string{"partition_value", "last_modified"}).AddRow("Taoyuan", "v2"),
	)
	want := errors.New("landed daily timetable could not be read")
	src := &fakeLoadSource{errs: map[string]error{"bus_dailytimetable|Taoyuan": want}}
	loaded := map[string]string{"Taoyuan": "v1"}
	// The source fails before the transform, so this fixture needs no DB or Redis writer.
	err = loadChangedBusDailyTimetables(context.Background(), db, src, nil, nil, loaded)
	if !errors.Is(err, want) {
		t.Fatalf("hourly load error = %v, want source error", err)
	}
	if !reflect.DeepEqual(src.calls, []string{"bus_dailytimetable|Taoyuan"}) {
		t.Fatalf("source reads = %v, want changed city exactly once", src.calls)
	}
	if !reflect.DeepEqual(loaded, map[string]string{"Taoyuan": "v1"}) {
		t.Fatalf("failed load advanced last-successful marker: %v", loaded)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestForcedRawRelandStopsWhenMarkerInvalidationFails(t *testing.T) {
	want := errors.New("durable marker could not be invalidated")
	var fetches, invalidations, verifications int
	fetcher := fakeRawFetcher{getInto: func(
		_ context.Context, _, _ string, _ func(shared.TDXIntoCommit) error,
	) (shared.TDXIntoResult, error) {
		fetches++
		return shared.TDXIntoResult{
			Marker: "landed-version",
			Invalidate: func() error {
				invalidations++
				return want
			},
		}, nil
	}}
	verify := func(context.Context, raw.Target, string, string) error {
		verifications++
		return nil
	}
	err := fetchRawWithVerifier(
		context.Background(), fetcher, "/v2/Bus/Route/City/Taipei", "bus_route_Taipei", "scheduled-full-run",
		true, verify,
	)
	if !errors.Is(err, want) {
		t.Fatalf("forced reland error = %v, want invalidation error", err)
	}
	if fetches != 1 || invalidations != 1 || verifications != 0 {
		t.Fatalf("fetches=%d invalidations=%d verifications=%d, want 1/1/0", fetches, invalidations, verifications)
	}
}

func TestScheduledFullRelandRequiresWholeSundayRun(t *testing.T) {
	taipei := time.FixedZone("Asia/Taipei", 8*60*60)
	sunday := time.Date(2026, time.October, 11, 3, 0, 0, 0, taipei)
	monday := time.Date(2026, time.October, 12, 3, 0, 0, 0, taipei)
	cases := []struct {
		name string
		only map[string]bool
		now  time.Time
		want bool
	}{
		{name: "Sunday whole run", now: sunday, want: true},
		{name: "Sunday selected dataset", only: map[string]bool{"bus_route": true}, now: sunday},
		{name: "Monday whole run", now: monday},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := fullRawReland(tc.only, tc.now); got != tc.want {
				t.Fatalf("scheduled full reland = %v, want %v", got, tc.want)
			}
		})
	}
}
