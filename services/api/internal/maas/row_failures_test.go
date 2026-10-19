package maas

import (
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/pashagolub/pgxmock/v4"
)

func maasRows(t *testing.T, data *pgxmock.Rows) pgx.Rows {
	t.Helper()
	db, err := pgxmock.NewPool()
	if err != nil {
		t.Fatal(err)
	}
	db.ExpectQuery("SELECT").WillReturnRows(data).RowsWillBeClosed()
	rows, err := db.Query(t.Context(), "SELECT")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		rows.Close()
		if err := db.ExpectationsWereMet(); err != nil {
			t.Error(err)
		}
		db.Close()
	})
	return rows
}

func TestFareBatchDiscardsPartialResultsOnScanOrIterationFailure(t *testing.T) {
	for _, kind := range []string{"scan", "iteration"} {
		t.Run(kind, func(t *testing.T) {
			route := &pb.Route{}
			section := &pb.Section{}
			db, err := pgxmock.NewPool()
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			data := pgxmock.NewRows([]string{"index", "fare"}).AddRow(int32(0), int32(20))
			if kind == "scan" {
				data.AddRow(int32(0), "invalid")
			} else {
				// A close error models an iteration failure after all completed rows.
				data.CloseError(errors.New("interrupted"))
			}
			db.ExpectQuery("WITH input").WithArgs([]int32{0}, []string{"metro"}, []string{"from"}, []string{"to"}).WillReturnRows(data).RowsWillBeClosed()
			querySectionFareBatch(t.Context(), db, sectionFareBatch{indices: []int32{0}, modes: []string{"metro"}, departures: []string{"from"}, arrivals: []string{"to"}, byIndex: map[int32]maasSectionRef{0: {target: section, route: route}}})
			if section.Fare != 0 || route.TotalFare != 0 {
				t.Fatalf("partial fare was published: section=%d, route=%d", section.Fare, route.TotalFare)
			}
			if err := db.ExpectationsWereMet(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestFareBatchIgnoresUnrequestedNonpositiveAndHigherDuplicateFare(t *testing.T) {
	data := pgxmock.NewRows([]string{"index", "fare"}).
		AddRow(int32(0), int32(30)).AddRow(int32(0), int32(20)).AddRow(int32(0), int32(40)).
		AddRow(int32(1), int32(99)).AddRow(int32(0), int32(0)).AddRow(int32(0), int32(-1))
	fares, ok := readSectionFares(maasRows(t, data), map[int32]maasSectionRef{0: {}})
	if !ok || len(fares) != 1 || fares[0] != 20 {
		t.Fatalf("fare batch=%v, complete=%v", fares, ok)
	}
}

func TestBusIdentityRequiresSingleMatchAndKnownSection(t *testing.T) {
	single, ambiguous, zero := &pb.Section{}, &pb.Section{}, &pb.Section{}
	data := pgxmock.NewRows([]string{"index", "route", "direction", "departure", "arrival", "count"}).
		AddRow(int32(0), "route", int32(1), "from", "to", int64(1)).
		AddRow(int32(1), "ambiguous", int32(0), "from", "to", int64(2)).
		AddRow(int32(2), "missing", int32(0), "from", "to", int64(0)).
		AddRow(int32(3), "unknown", int32(0), "from", "to", int64(1))
	applyBusNotificationRows(maasRows(t, data), map[int32]*pb.Section{0: single, 1: ambiguous, 2: zero})
	if id := single.NotificationIdentity; id == nil || !id.Supported || id.RouteKey != "route" || id.Direction != "1" || id.DepartureStopKey != "from" || id.ArrivalStopKey != "to" {
		t.Fatalf("single identity=%v", id)
	}
	if ambiguous.NotificationIdentity != nil || zero.NotificationIdentity != nil {
		t.Fatal("unresolved identity was published")
	}
}

func TestBusIdentityKeepsCompletedRowsAfterReadFailure(t *testing.T) {
	for _, kind := range []string{"scan", "iteration"} {
		t.Run(kind, func(t *testing.T) {
			data := pgxmock.NewRows([]string{"index", "route", "direction", "departure", "arrival", "count"}).AddRow(int32(0), "route", int32(0), "from", "to", int64(1))
			if kind == "scan" {
				data.AddRow(int32(1), "route", "invalid", "from", "to", int64(1))
			} else {
				data.CloseError(errors.New("interrupted"))
			}
			first, second := &pb.Section{}, &pb.Section{}
			applyBusNotificationRows(maasRows(t, data), map[int32]*pb.Section{0: first, 1: second})
			if !first.GetNotificationIdentity().GetSupported() || second.NotificationIdentity != nil {
				t.Fatalf("partial identity result=%v/%v", first, second)
			}
		})
	}
}
