package bus

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/pipeline/internal/raw"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/dataset"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
)

// dataTaipeiSpecTimeTable is the GetSpecTimeTable envelope. Every list in it is
// wrapped in a singular-named object (timeTables.timeTable), an XML shape
// carried over into the JSON.
type dataTaipeiSpecTimeTable struct {
	SpecificTimeTables struct {
		SpecificTimeTable []dataTaipeiSpecEntry `json:"specificTimeTable"`
	} `json:"specificTimeTables"`
}

// dataTaipeiSpecEntry is one subroute direction's filed schedule.
type dataTaipeiSpecEntry struct {
	SubRouteID string `json:"subRouteID"`
	Direction  string `json:"direction"`
	TimeTables struct {
		TimeTable []dataTaipeiSpecTrip `json:"timeTable"`
	} `json:"timeTables"`
}

// dataTaipeiSpecTrip is one departure, with the dates it is filed for.
type dataTaipeiSpecTrip struct {
	StopTimes struct {
		StopTime []dataTaipeiSpecStopTime `json:"stopTime"`
	} `json:"stopTimes"`
	SpecialDays struct {
		SpecialDay []dataTaipeiSpecialDay `json:"specialDay"`
	} `json:"specialDays"`
}

type dataTaipeiSpecStopTime struct {
	StopSequence  int64  `json:"stopSequence"`
	StopID        string `json:"stopID"`
	ArrivalTime   string `json:"arrivalTime"`
	DepartureTime string `json:"departureTime"`
}

type dataTaipeiSpecialDay struct {
	Dates struct {
		Date []string `json:"date"`
	} `json:"dates"`
	ServiceStatus string `json:"serviceStatus"`
}

// busDailyKey groups the reshaped trips by the subroute direction they belong to.
type busDailyKey struct {
	subRouteUID string
	direction   uint8
}

// _dataTaipeiServiceRunning is the serviceStatus for 正常營運. 0 is 停止營運 and 2
// is 加班營運; only a running trip belongs in a timetable of departures.
const _dataTaipeiServiceRunning = "1"

type busDailyTimetableRow struct {
	SubRouteUID string                  `json:"SubRouteUID"`
	Direction   uint8                   `json:"Direction"`
	BusDate     string                  `json:"BusDate"`
	Timetables  []busDailyTimetableTrip `json:"Timetables"`
}

type busDailyTimetableTrip struct {
	TripID     string                      `json:"TripID"`
	IsLowFloor bool                        `json:"IsLowFloor"`
	StopTimes  []busDailyTimetableStopTime `json:"StopTimes"`
}

type busDailyTimetableStopTime struct {
	StopSequence  int64  `json:"StopSequence"`
	StopUID       string `json:"StopUID"`
	ArrivalTime   string `json:"ArrivalTime"`
	DepartureTime string `json:"DepartureTime"`
}

func dataTaipeiDailyTimetableRows(feed dataTaipeiSpecTimeTable, day time.Time) []busDailyTimetableRow {
	date := day.Format("2006-01-02")
	byKey := make(map[busDailyKey]*busDailyTimetableRow)
	var order []busDailyKey
	for _, entry := range feed.SpecificTimeTables.SpecificTimeTable {
		order = appendDataTaipeiEntry(entry, date, byKey, order)
	}
	return sortedDataTaipeiTimetableRows(byKey, order)
}

func sortedDataTaipeiTimetableRows(byKey map[busDailyKey]*busDailyTimetableRow, order []busDailyKey) []busDailyTimetableRow {
	rows := make([]busDailyTimetableRow, 0, len(order))
	for _, key := range order {
		row := byKey[key]
		// Stable output so an unchanged feed lands identical bytes: the map
		// iteration above fixes the row order, this fixes the trips within a row.
		sort.Slice(row.Timetables, func(i, j int) bool {
			return row.Timetables[i].TripID < row.Timetables[j].TripID
		})
		rows = append(rows, *row)
	}
	return rows
}

// dataTaipeiRunsOn reports whether any of a trip's special-day entries puts it
// in normal service on date.
func dataTaipeiRunsOn(days []dataTaipeiSpecialDay, date string) bool {
	for _, d := range days {
		if dataTaipeiSpecialDayMatches(d, date) {
			return true
		}
	}
	return false
}

func LandDataTaipeiDailyTimetable(ctx context.Context, f *dataTaipeiFeed, now func() time.Time) error {
	var feed dataTaipeiSpecTimeTable
	if _, err := f.getEnvelope(ctx, "GetSpecTimeTable", &feed); err != nil {
		return _oops.Wrapf(err, "fetch Data.taipei spec timetable")
	}
	day := now().In(pipeline.Taipei)
	rows := dataTaipeiDailyTimetableRows(feed, day)
	return landDataTaipeiRows(ctx, day, rows)
}

func landDataTaipeiRows(ctx context.Context, day time.Time, rows []busDailyTimetableRow) error {
	body, err := json.Marshal(rows)
	if err != nil {
		return _oops.Wrapf(err, "encode Data.taipei daily timetable")
	}
	return dumpDataTaipeiRows(ctx, day, rows, body)
}

func dumpDataTaipeiRows(ctx context.Context, day time.Time, rows []busDailyTimetableRow, body []byte) error {
	cycle, err := raw.NewLandingCycle()
	if err != nil {
		return err
	}
	// The marker records which service date these rows describe. The blob's own
	// ETag would go stale in the wrong direction: it stays put across midnight
	// while the rows it produces change.
	marker := "datataipei:" + day.Format("2006-01-02")
	target := raw.Target{Table: "bus_dailytimetable", PartCol: "city", PartVal: dataset.DataTaipeiCity}
	if err := raw.Dump(ctx, target, marker, cycle, body); err != nil {
		return err
	}
	zap.S().Infow("landed",
		"component", "ingest",
		"action", "datataipei_dailytimetable",
		"event", "landed",
		"city", dataset.DataTaipeiCity,
		"date", marker,
		"subroute_directions", len(rows),
	)
	return nil
}

func dataTaipeiTripStopTimes(trip dataTaipeiSpecTrip) []busDailyTimetableStopTime {
	stopTimes := make([]busDailyTimetableStopTime, 0, len(trip.StopTimes.StopTime))
	for _, st := range trip.StopTimes.StopTime {
		if !validDataTaipeiStop(st) {
			continue
		}
		stopTimes = append(stopTimes, busDailyTimetableStopTime{
			StopSequence:  st.StopSequence,
			StopUID:       _dataTaipeiUIDPrefix + st.StopID,
			ArrivalTime:   st.ArrivalTime,
			DepartureTime: st.DepartureTime,
		})
	}
	return stopTimes
}

func appendDataTaipeiEntry(entry dataTaipeiSpecEntry, date string, byKey map[busDailyKey]*busDailyTimetableRow, order []busDailyKey) []busDailyKey {
	direction, ok := dataTaipeiDirection(entry.Direction)
	if !ok || strings.TrimSpace(entry.SubRouteID) == "" {
		return order
	}
	key := busDailyKey{subRouteUID: _dataTaipeiUIDPrefix + entry.SubRouteID, direction: direction}
	return appendDataTaipeiTrips(entry.TimeTables.TimeTable, date, key, byKey, order)
}
func appendDataTaipeiTrips(trips []dataTaipeiSpecTrip, date string, key busDailyKey, byKey map[busDailyKey]*busDailyTimetableRow, order []busDailyKey) []busDailyKey {
	for _, trip := range trips {
		if !dataTaipeiRunsOn(trip.SpecialDays.SpecialDay, date) {
			continue
		}
		order = appendDataTaipeiTrip(trip, date, key, byKey, order)
	}
	return order
}
func appendDataTaipeiTrip(trip dataTaipeiSpecTrip, date string, key busDailyKey, byKey map[busDailyKey]*busDailyTimetableRow, order []busDailyKey) []busDailyKey {
	stopTimes := dataTaipeiTripStopTimes(trip)
	if len(stopTimes) == 0 {
		return order
	}
	row, seen := byKey[key]
	if !seen {
		row = &busDailyTimetableRow{SubRouteUID: key.subRouteUID, Direction: key.direction, BusDate: date}
		byKey[key] = row
		order = append(order, key)
	}
	row.Timetables = append(row.Timetables, busDailyTimetableTrip{
		TripID: date + "-" + strings.ReplaceAll(stopTimes[0].DepartureTime, ":", ""), StopTimes: stopTimes,
	})
	return order
}
func dataTaipeiSpecialDayMatches(day dataTaipeiSpecialDay, date string) bool {
	if day.ServiceStatus != _dataTaipeiServiceRunning {
		return false
	}
	for _, on := range day.Dates.Date {
		if on == date {
			return true
		}
	}
	return false
}
func validDataTaipeiStopIdentity(stop dataTaipeiSpecStopTime) bool {
	return stop.StopSequence > 0 && strings.TrimSpace(stop.StopID) != ""
}

func validDataTaipeiStop(stop dataTaipeiSpecStopTime) bool {
	return validDataTaipeiStopIdentity(stop) && validTimetableClockPair(stop.ArrivalTime, stop.DepartureTime)
}
