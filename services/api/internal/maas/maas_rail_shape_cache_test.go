package maas

import (
	"errors"
	"reflect"
	"testing"

	"github.com/pashagolub/pgxmock/v4"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
)

func expectRailClip(db pgxmock.PgxPoolIface, a, b transitStopPoint, wkt string) {
	db.ExpectQuery("WITH candidates").
		WithArgs("metro", a.lng, a.lat, b.lng, b.lat, _railShapeSnapMeters, _railShapeSimplifyTolerance).
		WillReturnRows(pgxmock.NewRows([]string{"wkt"}).AddRow(wkt)).RowsWillBeClosed()
}

func TestRailShapeCacheQueriesEachHopOnce(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a, b, c := transitStopPoint{25, 121}, transitStopPoint{26, 122}, transitStopPoint{27, 123}
	expectRailClip(db, a, b, "LINESTRING(121 25,121.5 25.5,122 26)")
	expectRailClip(db, b, c, "LINESTRING(122 26,123 27)")
	shapes := newRailShapeCache()

	want := []*pb.Location{{Lat: 25, Lng: 121}, {Lat: 25.5, Lng: 121.5}, {Lat: 26, Lng: 122}}
	for call := range 3 {
		got, ok := shapes.clip(t.Context(), db, "metro", a, b)
		if !ok || !reflect.DeepEqual(got, want) {
			t.Fatalf("clip %d = %v, %v; want %v", call, got, ok, want)
		}
	}
	if got, ok := shapes.clip(t.Context(), db, "metro", b, c); !ok || len(got) != 2 {
		t.Fatalf("second hop = %v, %v; a different hop must query on its own", got, ok)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatalf("a repeated hop queried again: %v", err)
	}
}

func TestRailShapeCacheDoesNotKeepFailures(t *testing.T) {
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	a, b := transitStopPoint{25, 121}, transitStopPoint{26, 122}
	db.ExpectQuery("WITH candidates").
		WithArgs("metro", a.lng, a.lat, b.lng, b.lat, _railShapeSnapMeters, _railShapeSimplifyTolerance).
		WillReturnError(errors.New("pool exhausted"))
	expectRailClip(db, a, b, "LINESTRING(121 25,122 26)")
	shapes := newRailShapeCache()

	if got, ok := shapes.clip(t.Context(), db, "metro", a, b); ok || got != nil {
		t.Fatalf("failed clip = %v, %v", got, ok)
	}
	if got, ok := shapes.clip(t.Context(), db, "metro", a, b); !ok || len(got) != 2 {
		t.Fatalf("retry after failure = %v, %v; the failure was cached", got, ok)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestRailShapeCacheSeparatesModesAndDirections(t *testing.T) {
	a, b := transitStopPoint{25, 121}, transitStopPoint{26, 122}
	keys := map[string]bool{
		railShapeKey("metro", a, b): true,
		railShapeKey("metro", b, a): true,
		railShapeKey("tra", a, b):   true,
	}
	if len(keys) != 3 {
		t.Fatalf("keys collide: %v", keys)
	}
	if railShapeKey("metro", transitStopPoint{25.0330001, 121}, b) == railShapeKey("metro", transitStopPoint{25.0330002, 121}, b) {
		t.Fatal("nearby stops share a key")
	}
}

func TestRailShapeCacheFallsThroughWhenUncacheable(t *testing.T) {
	var shapes *railShapeCache
	if got, ok := shapes.clip(t.Context(), nil, "metro", transitStopPoint{25, 121}, transitStopPoint{26, 122}); ok || got != nil {
		t.Fatalf("nil cache and db = %v, %v", got, ok)
	}
	if got, ok := newRailShapeCache().clip(t.Context(), nil, "metro", transitStopPoint{25, 121}, transitStopPoint{26, 122}); ok || got != nil {
		t.Fatalf("nil db = %v, %v", got, ok)
	}
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if got, ok := newRailShapeCache().clip(t.Context(), db, "metro", transitStopPoint{}, transitStopPoint{26, 122}); ok || got != nil {
		t.Fatalf("unusable endpoint = %v, %v", got, ok)
	}
	if err := db.ExpectationsWereMet(); err != nil {
		t.Fatalf("unusable endpoint queried: %v", err)
	}
}
