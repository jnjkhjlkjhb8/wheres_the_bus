package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"github.com/pashagolub/pgxmock/v4"
)

func TestDailyLandingMarkerReadRejectsEveryReadFailure(t *testing.T) {
	want := errors.New("marker read failed")
	for _, phase := range []string{"query", "scan", "rows", "success", "empty"} {
		t.Run(phase, func(t *testing.T) {
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			query := db.ExpectQuery("SELECT partition_value, last_modified")
			rows := db.NewRows([]string{"partition_value", "last_modified"})
			switch phase {
			case "query":
				query.WillReturnError(want)
			case "scan":
				query.WillReturnRows(rows.AddRow(struct{}{}, "v1"))
			case "rows":
				query.WillReturnRows(rows.AddRow("Taipei", "v1").CloseError(want))
			case "success":
				query.WillReturnRows(rows.AddRow("Taipei", "v1").AddRow("Taoyuan", "v2"))
			case "empty":
				query.WillReturnRows(rows)
			}
			markers, err := busDailyLandingMarkers(context.Background(), db)
			switch phase {
			case "success":
				if err != nil || !reflect.DeepEqual(markers, map[string]string{"Taipei": "v1", "Taoyuan": "v2"}) {
					t.Fatalf("markers = %v, %v", markers, err)
				}
			case "empty":
				if err != nil || len(markers) != 0 {
					t.Fatalf("empty markers = %v, %v", markers, err)
				}
			default:
				if err == nil {
					t.Fatal("failed marker read succeeded")
				}
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestHourlyLoadRecordsSuccessfulCitiesAfterOtherCitiesFail(t *testing.T) {
	want := errors.New("Taichung transform failed")
	src := &fakeLoadSource{fetched: time.Now()}
	var called []string
	base := loadSpec{key: "probe", table: "probe", load: func(_ context.Context, _ *json.Decoder, _ pipeline.CopyUpsertSink, city string) error {
		called = append(called, city)
		if city == "Taichung" {
			return want
		}
		return nil
	}}
	loaded := map[string]string{"Taichung": "old"}
	markers := map[string]string{"Taichung": "new", "Taoyuan": "v2"}
	err := loadBusDailyPendingCities(context.Background(), src, nil, nil, base, markers, loaded)
	if !errors.Is(err, want) || !reflect.DeepEqual(called, []string{"Taichung", "Taoyuan"}) {
		t.Fatalf("partial load = %v, %v", called, err)
	}
	if !reflect.DeepEqual(loaded, map[string]string{"Taichung": "old", "Taoyuan": "v2"}) {
		t.Fatalf("successful marker progress = %v", loaded)
	}
}

func TestHourlyLoadWithNoLandingMarkersDoesNoTransform(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.ExpectQuery("SELECT partition_value, last_modified").WillReturnRows(db.NewRows([]string{"partition_value", "last_modified"}))
	src := &fakeLoadSource{fetched: time.Now()}
	if err := loadChangedBusDailyTimetables(context.Background(), db, src, nil, nil, map[string]string{}); err != nil {
		t.Fatal(err)
	}
	if len(src.calls) != 0 {
		t.Fatalf("quiet hour read source: %v", src.calls)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestLoadedDailyMarkersRoundTripAndCancellation(t *testing.T) {
	rc := dialTestRedis(t)
	defer func() { _ = rc.Close() }()
	ctx := context.Background()
	city := fmt.Sprintf("quality-%d", time.Now().UnixNano())
	t.Cleanup(func() { _ = rc.HDel(context.Background(), _busDailyLoadedKey, city).Err() })
	if err := writeLoadedDailyMarkers(ctx, rc, map[string]string{city: "v1"}); err != nil {
		t.Fatal(err)
	}
	loaded, err := readLoadedDailyMarkers(ctx, rc)
	if err != nil || loaded[city] != "v1" {
		t.Fatalf("loaded marker = %v, %v", loaded[city], err)
	}
	if err := writeLoadedDailyMarkers(ctx, nil, nil); err != nil {
		t.Fatal(err)
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := readLoadedDailyMarkers(cancelled, rc); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled read = %v", err)
	}
	if err := writeLoadedDailyMarkers(cancelled, rc, map[string]string{city: "v2"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled write = %v", err)
	}
}
