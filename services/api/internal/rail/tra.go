package rail

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// railDB is the read surface the rail handlers need. Both *pgxpool.Pool and the
// pgxmock pool satisfy it, so read-path helpers can be unit-tested with a mock.
type railDB interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

type traTimetableRow struct {
	TrainDate           time.Time `db:"train_date"`
	Trainno             string    `db:"trainno"`
	StartingStationID   string    `db:"starting_station_id"`
	StartingStationName string    `db:"starting_station_name"`
	EndingStationID     string    `db:"ending_station_id"`
	EndingStationName   string    `db:"ending_station_name"`
	TrainTypeID         string    `db:"train_type_id"`
	TrainTypeCode       string    `db:"train_type_code"`
	TrainTypeName       string    `db:"train_type_name"`
	Tripline            int32     `db:"tripline"`
	Stopsequence        int       `db:"stopsequence"`
	Stationid           string    `db:"stationid"`
	Stationname         string    `db:"stationname"`
	Arrivaltime         time.Time `db:"arrivaltime"`
	Departuretime       time.Time `db:"departuretime"`
	Mask                int32     `db:"mask"`
	Note                string    `db:"note"`
}
type traStationBoardRow struct {
	TrainDate         time.Time `db:"train_date"`
	Trainno           string    `db:"trainno"`
	TrainTypeCode     string    `db:"train_type_code"`
	TrainTypeName     string    `db:"train_type_name"`
	EndingStationName string    `db:"ending_station_name"`
	Departuretime     time.Time `db:"departuretime"`
	Direction         int32     `db:"direction"`
	Mask              int32     `db:"mask"`
	Note              string    `db:"note"`
}
type traStopsRow struct {
	Stopsequence  int    `db:"stopsequence"`
	Stationid     string `db:"stationid"`
	Stationname   string `db:"stationname"`
	Arrivaltime   string `db:"arrivaltime"`
	Departuretime string `db:"departuretime"`
	Mask          int32  `db:"mask"`
}
type traFareRow struct {
	TicketType string `db:"ticket_type"`
	Price      int32  `db:"price"`
}

var _traTicketTypes = buildTraTicketTypes()

func buildTraTicketTypes() []string {
	fareKinds := []string{"成", "孩", "敬", "愛"}
	trainKinds := []string{"自", "莒", "復", "普"}
	out := make([]string, 0, len(fareKinds)*len(trainKinds))
	for _, fareKind := range fareKinds {
		for _, trainKind := range trainKinds {
			out = append(out, fareKind+trainKind)
		}
	}
	return out
}

func TRAFarePayload(ctx context.Context, db railDB, start, end string) ([]byte, error) {
	start, err := resolveRailStationID(ctx, db, "tra_stations", start)
	if err != nil {
		return nil, err
	}
	end, err = resolveRailStationID(ctx, db, "tra_stations", end)
	if err != nil {
		return nil, err
	}
	const q = `SELECT ticket_type,price FROM tra_fares WHERE origin_station_id = $1 AND destination_station_id = $2 AND ticket_type = ANY($3) AND price > 0 ORDER BY price DESC, ticket_type;`
	rows, err := db.Query(ctx, q, start, end, _traTicketTypes)
	if err != nil {
		return nil, err
	}
	row, err := pgx.CollectRows(rows, pgx.RowToAddrOfStructByName[traFareRow])
	if err != nil {
		return nil, err
	}
	if len(row) == 0 {
		return nil, nil
	}
	arr := make([]*models.TraFareItem, 0, len(row))
	for _, temp := range row {
		arr = append(arr, &models.TraFareItem{
			TicketType: temp.TicketType,
			Price:      temp.Price,
		})
	}
	return proto.Marshal(&models.TraFareItems{Items: arr})
}

func TRAStoptimesPayload(ctx context.Context, db railDB, trainno, dateStr string) ([]byte, int, error) {
	const q = `SELECT stopsequence, stationid,stationname,arrivaltime,departuretime,mask FROM tra_timetable WHERE trainno = $1 AND train_date = $2 ORDER BY stopsequence;`
	rows, err := db.Query(ctx, q, trainno, dateStr)
	if err != nil {
		return nil, 0, err
	}
	row, err := pgx.CollectRows(rows, pgx.RowToAddrOfStructByName[traStopsRow])
	if err != nil {
		return nil, 0, err
	}
	arr := make([]*models.TraStoptime, 0, len(row))
	for _, temp := range row {
		arr = append(arr, &models.TraStoptime{
			StopSequence:  int32(temp.Stopsequence),
			StationId:     temp.Stationid,
			StationName:   temp.Stationname,
			ArrivalTime:   temp.Arrivaltime,
			DepartureTime: temp.Departuretime,
			SuspendedFlag: (temp.Mask & (1 << 7)) != 0,
		})
	}
	b, err := proto.Marshal(&models.TraStoptimes{Items: arr})
	if err != nil {
		return nil, 0, err
	}
	return b, len(row), nil
}

func TRAStationBoardPayload(ctx context.Context, db railDB, station string, date time.Time, direction int32) ([]*models.TraStationDeparture, error) {
	station, err := resolveRailStationID(ctx, db, "tra_stations", station)
	if err != nil {
		return nil, err
	}
	const q = `SELECT train_date,trainno,train_type_code,train_type_name,ending_station_name,departuretime,direction,mask,note FROM tra_timetable WHERE stationid = $1 AND train_date = $2 AND direction = $3 AND stationid <> ending_station_id ORDER BY departuretime;`
	rows, err := db.Query(ctx, q, station, date.Format(time.DateOnly), direction)
	if err != nil {
		return nil, err
	}
	row, err := pgx.CollectRows(rows, pgx.RowToAddrOfStructByName[traStationBoardRow])
	if err != nil {
		return nil, err
	}
	arr := make([]*models.TraStationDeparture, 0, len(row))
	for _, temp := range row {
		arr = append(arr, &models.TraStationDeparture{
			TrainDate:                temp.TrainDate.Format(time.DateOnly),
			TrainNo:                  temp.Trainno,
			TrainTypeCode:            temp.TrainTypeCode,
			TrainTypeName:            temp.TrainTypeName,
			Destination_Station_Name: temp.EndingStationName,
			DepartureTime:            temp.Departuretime.Format(time.TimeOnly),
			Direction:                temp.Direction,
			Mask:                     temp.Mask,
			Note:                     temp.Note,
		})
	}
	return arr, nil
}

func TRATimetablePayload(ctx context.Context, db railDB, start, end string, date time.Time) ([]byte, int, error) {
	start, err := resolveRailStationID(ctx, db, "tra_stations", start)
	if err != nil {
		return nil, 0, err
	}
	end, err = resolveRailStationID(ctx, db, "tra_stations", end)
	if err != nil {
		return nil, 0, err
	}
	const combined = `SELECT train_date,trainno, starting_station_id,starting_station_name,ending_station_id,ending_station_name, stopsequence,train_type_id,train_type_code,train_type_name,tripline,stationid,arrivaltime,stationname,mask,note,departuretime FROM tra_timetable WHERE stationid = ANY($1) AND train_date = $2 AND (stationid <> $3 OR departuretime >= $4) ORDER BY trainno, stopsequence, stationid;`
	stations := []string{start, end}
	rows, err := db.Query(ctx, combined, stations, date.Format(time.DateOnly), start, date.Format(time.TimeOnly))
	if err != nil {
		return nil, 0, err
	}
	row, err := pgx.CollectRows(rows, pgx.RowToAddrOfStructByName[traTimetableRow])
	if err != nil {
		return nil, 0, err
	}
	mp := make(map[string]*models.TraTimetable)
	startSeq := make(map[string]int)
	arr := make([]*models.TraTimetable, 0, len(row))
	for _, temp := range row {
		if temp.Stationid == start {
			startSeq[temp.Trainno] = temp.Stopsequence
			mp[temp.Trainno] = &models.TraTimetable{
				TrainDate:             temp.TrainDate.Format(time.DateOnly),
				TrainNo:               temp.Trainno,
				Starting_Station_Name: temp.StartingStationName,
				Ending_Station_Name:   temp.EndingStationName,
				TrainTypeCode:         temp.TrainTypeCode,
				TrainTypeName:         temp.TrainTypeName,
				TrainTypeID:           temp.TrainTypeID,
				TripLine:              temp.Tripline,
				Mask:                  temp.Mask,
				Note:                  temp.Note,
				// The origin leg is a departure, not an arrival: a train
				// originating at the queried station has no arrival time there.
				Starting_Time: temp.Departuretime.Format(time.RFC3339),
			}
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
		w, err := time.Parse(time.RFC3339, seed.Starting_Time)
		if err != nil {
			zap.S().Errorw("parse time error", "err", err)
			continue
		}
		t := temp.Arrivaltime
		duration := t.Sub(w)
		if duration < 0 {
			duration += 24 * time.Hour
		}
		seed.Ending_Time = t.Format(time.RFC3339)
		seed.Travel_Time = duration.String()
		arr = append(arr, seed)
	}
	b, err := proto.Marshal(&models.TraTimetables{Items: arr})
	if err != nil {
		return nil, 0, err
	}
	return b, len(arr), nil
}

// isNumericStationID reports whether s is already a numeric station code (TRA
// and THSR ids are digit strings) rather than a station name needing resolution.
func isNumericStationID(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func resolveRailStationID(ctx context.Context, db railDB, table, s string) (string, error) {
	if isNumericStationID(s) {
		return s, nil
	}
	rows, err := db.Query(ctx,
		`SELECT station_id FROM `+table+
			` WHERE replace(name, '臺', '台') = replace($1, '臺', '台') ORDER BY station_id LIMIT 1`, s)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	if rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return "", err
		}
		return id, nil
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	return s, nil
}
