package rail

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

type thsrTimetableRow struct {
	Trainno             string `db:"trainno"`
	StartingStationID   string `db:"starting_station_id"`
	StartingStationName string `db:"starting_station_name"`
	EndingStationID     string `db:"ending_station_id"`
	EndingStationName   string `db:"ending_station_name"`
	Arrivaltime         string `db:"arrivaltime"`
	Departuretime       string `db:"departuretime"`
	Note                string `db:"note"`
	Overnight           bool   `db:"overnight"`
	Stationid           string `db:"stationid"`
	Stopsequence        int    `db:"stopsequence"`
}
type thsrStopsRow struct {
	Stopsequence  int    `db:"stopsequence"`
	Stationid     string `db:"stationid"`
	Stationname   string `db:"stationname"`
	Arrivaltime   string `db:"arrivaltime"`
	Departuretime string `db:"departuretime"`
}
type thsrStationBoardRow struct {
	TrainDate         time.Time `db:"train_date"`
	Trainno           string    `db:"trainno"`
	EndingStationName string    `db:"ending_station_name"`
	Departuretime     string    `db:"departuretime"`
	Direction         int32     `db:"direction"`
	Note              string    `db:"note"`
}
type thsrFareRow struct {
	TicketType uint8 `db:"ticket_type"`
	FareClass  uint8 `db:"fare_class"`
	CabinClass uint8 `db:"cabin_class"`
	Price      int32 `db:"price"`
}

func QueryTHSRFares(ctx context.Context, db railDB, start, end string) ([]*models.ThsaFare, error) {
	start, err := resolveRailStationID(ctx, db, "thsr_stations", start)
	if err != nil {
		return nil, err
	}
	end, err = resolveRailStationID(ctx, db, "thsr_stations", end)
	if err != nil {
		return nil, err
	}
	rows, err := db.Query(ctx, `SELECT ticket_type, fare_class, cabin_class, price FROM thsr_fares WHERE origin_station_id = $1 AND destination_station_id = $2 AND ticket_type = 1 AND price > 0 ORDER BY cabin_class, fare_class, price;`, start, end)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	row, err := pgx.CollectRows(rows, pgx.RowToAddrOfStructByName[thsrFareRow])
	if err != nil {
		return nil, err
	}
	arr := make([]*models.ThsaFare, 0, len(row))
	for _, temp := range row {
		arr = append(arr, &models.ThsaFare{
			CabinClas:  int32(temp.CabinClass),
			TicketType: int32(temp.TicketType),
			FareClass:  int32(temp.FareClass),
			Price:      temp.Price,
		})
	}
	return arr, rows.Err()
}

func THSRStoptimesPayload(ctx context.Context, db railDB, trainno, dateStr string) ([]byte, int, error) {
	const q = `SELECT stopsequence, stationid,stationname,arrivaltime,departuretime FROM thsr_timetable WHERE trainno = $1 AND train_date = $2 ORDER BY stopsequence;`
	rows, err := db.Query(ctx, q, trainno, dateStr)
	if err != nil {
		return nil, 0, err
	}
	row, err := pgx.CollectRows(rows, pgx.RowToAddrOfStructByName[thsrStopsRow])
	if err != nil {
		return nil, 0, err
	}
	arr := make([]*models.ThsaStoptime, 0, len(row))
	for _, temp := range row {
		arr = append(arr, &models.ThsaStoptime{
			StopSequence:  int32(temp.Stopsequence),
			StationId:     temp.Stationid,
			StationName:   temp.Stationname,
			ArrivalTime:   temp.Arrivaltime,
			DepartureTime: temp.Departuretime,
		})
	}
	b, err := proto.Marshal(&models.ThsrStoptimes{Items: arr})
	if err != nil {
		return nil, 0, err
	}
	return b, len(row), nil
}

func THSRStationBoardPayload(ctx context.Context, db railDB, station string, date time.Time, direction int32) ([]*models.ThsrStationDeparture, error) {
	station, err := resolveRailStationID(ctx, db, "thsr_stations", station)
	if err != nil {
		return nil, err
	}
	const q = `SELECT train_date,trainno,ending_station_name,departuretime,direction,note FROM thsr_timetable WHERE stationid = $1 AND train_date = $2 AND direction = $3 AND stationid <> ending_station_id ORDER BY departuretime;`
	rows, err := db.Query(ctx, q, station, date.Format(time.DateOnly), direction)
	if err != nil {
		return nil, err
	}
	row, err := pgx.CollectRows(rows, pgx.RowToAddrOfStructByName[thsrStationBoardRow])
	if err != nil {
		return nil, err
	}
	arr := make([]*models.ThsrStationDeparture, 0, len(row))
	for _, temp := range row {
		arr = append(arr, &models.ThsrStationDeparture{
			TrainDate:                temp.TrainDate.Format(time.DateOnly),
			TrainNo:                  temp.Trainno,
			Destination_Station_Name: temp.EndingStationName,
			DepartureTime:            temp.Departuretime,
			Direction:                temp.Direction,
			Note:                     temp.Note,
		})
	}
	return arr, nil
}

func THSRTimetablePayload(ctx context.Context, db railDB, start, end string, date time.Time) ([]byte, int, error) {
	start, err := resolveRailStationID(ctx, db, "thsr_stations", start)
	if err != nil {
		return nil, 0, err
	}
	end, err = resolveRailStationID(ctx, db, "thsr_stations", end)
	if err != nil {
		return nil, 0, err
	}
	const combined = `SELECT trainno, starting_station_id,starting_station_name,ending_station_id,ending_station_name,arrivaltime,departuretime,note,overnight,stationid,stopsequence FROM thsr_timetable WHERE stationid = ANY($1) AND train_date = $2 ORDER BY trainno, stopsequence, stationid;`
	stations := []string{start, end}
	rows, err := db.Query(ctx, combined, stations, date.Format(time.DateOnly))
	if err != nil {
		return nil, 0, err
	}
	row, err := pgx.CollectRows(rows, pgx.RowToAddrOfStructByName[thsrTimetableRow])
	if err != nil {
		return nil, 0, err
	}
	mp := make(map[string]*models.ThsaTimetable)
	startSeq := make(map[string]int)
	arr := make([]*models.ThsaTimetable, 0, len(row))
	for _, temp := range row {
		if temp.Stationid != start {
			continue
		}
		if temp.Departuretime < date.Format(time.TimeOnly) {
			continue
		}
		startSeq[temp.Trainno] = temp.Stopsequence
		mp[temp.Trainno] = &models.ThsaTimetable{
			TrainDate:             date.Format(time.DateOnly),
			TrainNo:               temp.Trainno,
			Starting_Station_Name: temp.StartingStationName,
			EndingStationName:     temp.EndingStationName,
			Note:                  temp.Note,
			Overnight:             temp.Overnight,
			Starting_Time:         temp.Departuretime,
		}
	}
	for _, temp := range row {
		if temp.Stationid != end {
			continue
		}
		seed, ok := mp[temp.Trainno]
		if !ok {
			continue
		}
		if temp.Stopsequence <= startSeq[temp.Trainno] {
			continue
		}
		w, err := time.Parse(time.TimeOnly, seed.Starting_Time)
		if err != nil {
			zap.S().Errorw("parse time error", "err", err)
			continue
		}
		t, err := time.Parse(time.TimeOnly, temp.Arrivaltime)
		if err != nil {
			zap.S().Errorw("parse time error", "err", err)
			continue
		}
		duration := t.Sub(w)
		if duration < 0 {
			duration += 24 * time.Hour
		}
		seed.Ending_Time = temp.Arrivaltime
		seed.Travel_Time = duration.String()
		arr = append(arr, seed)
	}
	b, err := proto.Marshal(&models.ThsrTimetables{Items: arr})
	if err != nil {
		return nil, 0, err
	}
	return b, len(arr), nil
}
