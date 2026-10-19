package raw

import (
	"bytes"
	"context"
	"errors"
	"regexp"
	"testing"

	pgxmock "github.com/pashagolub/pgxmock/v4"
)

func TestRawLandingRollsBackAtEveryPersistenceBoundary(t *testing.T) {
	for _, failAt := range []string{"begin", "lock", "delete", "insert", "state", "commit", "truncate"} {
		t.Run(failAt, func(t *testing.T) {
			db := newRawLandingMock(t)
			want := errors.New("failed " + failAt)
			target := Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}
			if failAt == "begin" {
				db.ExpectBegin().WillReturnError(want)
			} else {
				db.ExpectBegin()
				steps := []struct{ name, query string }{
					{"lock", regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'")},
					{"delete", regexp.QuoteMeta(rawDeleteSQL(target))},
					{"insert", regexp.QuoteMeta(rawInsertSQL(target.Table))},
					{"state", _stateUpsertPattern},
				}
				if failAt == "truncate" {
					target.PartCol = ""
					target.PartVal = ""
					steps[1] = struct{ name, query string }{"truncate", "TRUNCATE raw_tdx.bus_route"}
				}
				for _, step := range steps {
					expectation := db.ExpectExec(step.query)
					switch step.name {
					case "delete":
						expectation.WithArgs("Taipei")
					case "insert":
						expectation.WithArgs(`{"city":"Taipei"}`, []byte("[]"))
					case "state":
						expectation.WithArgs("bus_route", "city", "Taipei", "MARKER", int64(0), "cycle")
					}
					if step.name == failAt {
						expectation.WillReturnError(want)
						break
					}
					expectation.WillReturnResult(pgxmock.NewResult("OK", 0))
				}
				if failAt == "commit" {
					db.ExpectCommit().WillReturnError(want)
				}
				db.ExpectRollback()
			}
			err := landRawTDXWithDB(context.Background(), db, target, "MARKER", "cycle", bytes.NewBufferString(`[]`))
			if !errors.Is(err, want) {
				t.Fatalf("error = %v, want %v", err, want)
			}
		})
	}
}

func TestVerified304RollsBackAndKeepsOriginalError(t *testing.T) {
	for _, failAt := range []string{"lock", "state", "presence", "touch", "commit"} {
		t.Run(failAt, func(t *testing.T) {
			db := newRawLandingMock(t)
			want := errors.New("failed " + failAt)
			db.ExpectBegin()
			lock := db.ExpectExec(regexp.QuoteMeta("SET LOCAL lock_timeout = '20s'"))
			if failAt == "lock" {
				lock.WillReturnError(want)
			} else {
				lock.WillReturnResult(pgxmock.NewResult("SET", 0))
				state := db.ExpectQuery(_stateSelectForUpdatePattern).WithArgs("bus_route", "city", "Taipei")
				if failAt == "state" {
					state.WillReturnError(want)
				} else {
					state.WillReturnRows(pgxmock.NewRows([]string{"last_modified", "row_count"}).AddRow("MARKER", int64(0)))
					presence := db.ExpectQuery(`SELECT EXISTS`).WithArgs("Taipei")
					if failAt == "presence" {
						presence.WillReturnError(want)
					} else {
						presence.WillReturnRows(pgxmock.NewRows([]string{"exists"}).AddRow(false))
						touch := db.ExpectExec(_stateTouchPattern).WithArgs("bus_route", "city", "Taipei", "cycle")
						if failAt == "touch" {
							touch.WillReturnError(want)
						} else {
							touch.WillReturnResult(pgxmock.NewResult("UPDATE", 1))
							db.ExpectCommit().WillReturnError(want)
						}
					}
				}
			}
			db.ExpectRollback()
			err := VerifyAndTouchLandingWithDB(context.Background(), db, Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}, "MARKER", "cycle")
			if !errors.Is(err, want) {
				t.Fatalf("error = %v, want %v", err, want)
			}
		})
	}
}

func TestRawPublicWrappersRejectMissingPoolAndInvalidVerification(t *testing.T) {
	previous := DB
	DB = nil
	t.Cleanup(func() { DB = previous })
	target := Target{Table: "bus_route", PartCol: "city", PartVal: "Taipei"}
	if err := Dump(context.Background(), target, "M", "C", []byte(`[]`)); !errors.Is(err, errRawDump) {
		t.Fatalf("nil dump pool: %v", err)
	}
	if err := VerifyAndTouchLanding(context.Background(), target, "M", "C"); !errors.Is(err, errRawDump) {
		t.Fatalf("nil verify pool: %v", err)
	}
	if got := SinceFallback("tra_stations"); got != "" {
		t.Fatalf("nil fallback: %q", got)
	}
	for _, invalid := range []struct {
		target        Target
		marker, cycle string
	}{
		{Target{Table: "not_allowed"}, "M", "C"},
		{target, "", "C"},
		{target, "M", " "},
	} {
		if err := VerifyAndTouchLandingWithDB(context.Background(), nil, invalid.target, invalid.marker, invalid.cycle); err == nil {
			t.Fatal("invalid verification reached database")
		}
	}
}
