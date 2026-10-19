package rail

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
)

// railStation decodes a TDX TRA/THSR Station element, used for both the TRA and
// THSR static station tables.
type railStation struct {
	StationID   string `json:"StationID"`
	StationName struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"StationName"`
	LocationCityCode string `json:"LocationCityCode"`
	StationPosition  struct {
		PositionLon float64 `json:"PositionLon"`
		PositionLat float64 `json:"PositionLat"`
	} `json:"StationPosition"`
	StationCode string `json:"StationCode"`
}

// traFare decodes a TDX TRA/ODFare element: fares between a station pair by
// ticket type.
type traFare struct {
	OriginStationID      string `json:"OriginStationID"`
	DestinationStationID string `json:"DestinationStationID"`
	Fares                []struct {
		TicketType string `json:"TicketType"`
		Price      int32  `json:"Price"`
	} `json:"Fares"`
}

// thsrFare decodes a TDX THSR/ODFare element: fares between a station pair,
// further split by fare class and cabin class.
type thsrFare struct {
	OriginStationID      string `json:"OriginStationID"`
	DestinationStationID string `json:"DestinationStationID"`
	Fares                []struct {
		TicketType uint8  `json:"TicketType"`
		FareClass  uint8  `json:"FareClass"`
		CabinClass uint8  `json:"CabinClass"`
		Price      uint16 `json:"Price"`
	} `json:"Fares"`
}

// traDelay decodes a TDX TRA/LiveTrainDelay element: a train's current delay in
// minutes at a station.

// rawTraTimetable decodes a TDX TRA/DailyTimetable element: one train's info
// and its ordered stop times for a given service date.
type rawTraTimetable struct {
	TrainDate      string `json:"TrainDate"`
	DailyTrainInfo struct {
		TrainNo             string `json:"TrainNo"`
		Direction           *uint8 `json:"Direction"`
		StartingStationID   string `json:"StartingStationID"`
		StartingStationName struct {
			ZhTw string `json:"Zh_tw"`
		} `json:"StartingStationName"`
		EndingStationID   string `json:"EndingStationID"`
		EndingStationName struct {
			ZhTw string `json:"Zh_tw"`
		} `json:"EndingStationName"`
		TrainTypeID   string `json:"TrainTypeID"`
		TrainTypeCode string `json:"TrainTypeCode"`
		TrainTypeName struct {
			ZhTw string `json:"Zh_tw"`
		} `json:"TrainTypeName"`
		TripLine           uint8  `json:"TripLine"`
		WheelchairFlag     *uint8 `json:"WheelchairFlag"`
		PackageServiceFlag *uint8 `json:"PackageServiceFlag"`
		DiningFlag         *uint8 `json:"DiningFlag"`
		BikeFlag           *uint8 `json:"BikeFlag"`
		BreastFeedingFlag  *uint8 `json:"BreastFeedingFlag"`
		DailyFlag          *uint8 `json:"DailyFlag"`
		ServiceAddedFlag   *uint8 `json:"ServiceAddedFlag"`
		SuspendedFlag      *uint8 `json:"SuspendedFlag"`
		Note               struct {
			ZhTw string `json:"Zh_tw"`
		} `json:"Note"`
	} `json:"DailyTrainInfo"`
	StopTimes []railStopTime `json:"StopTimes"`
}

// rawThsrTimetable decodes a TDX THSR/DailyTimetable element: one high-speed
// train's info and stop times for a service date. Overnight marks a train that
// crosses midnight.
type rawThsrTimetable struct {
	TrainDate      string `json:"TrainDate"`
	DailyTrainInfo struct {
		TrainNo             string `json:"TrainNo"`
		Direction           *uint8 `json:"Direction"`
		StartingStationID   string `json:"StartingStationID"`
		StartingStationName struct {
			ZhTw string `json:"Zh_tw"`
		} `json:"StartingStationName"`
		EndingStationID   string `json:"EndingStationID"`
		EndingStationName struct {
			ZhTw string `json:"Zh_tw"`
		} `json:"EndingStationName"`
		Note struct {
			ZhTw string `json:"Zh_tw"`
		} `json:"Note"`
		Overnight *bool `json:"Overnight"`
	} `json:"DailyTrainInfo"`
	StopTimes []railStopTime `json:"StopTimes"`
}

type railStopTime struct {
	StopSequence uint8  `json:"StopSequence"`
	StationID    string `json:"StationID"`
	StationName  struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"StationName"`
	ArrivalTime   string `json:"ArrivalTime"`
	DepartureTime string `json:"DepartureTime"`
	SuspendedFlag *uint8 `json:"SuspendedFlag"`
}

// railTrainFlags holds a TRA train's amenity/service boolean flags (1 = set)
// before they are packed into a single bitmask by railMask.
type railTrainFlags struct {
	wheel     uint8
	pack      uint8
	dining    uint8
	bike      uint8
	breast    uint8
	daily     uint8
	service   uint8
	suspended uint8
}

// railMask packs a TRA train's amenity flags into a uint16 bitmask (bit 0 =
// wheelchair through bit 7 = suspended, in struct field order) for compact
// storage in tra_timetable.mask.
func railMask(f railTrainFlags) uint16 {
	var res uint16
	for i, v := range []uint8{f.wheel, f.pack, f.dining, f.bike, f.breast, f.daily, f.service, f.suspended} {
		if v == 1 {
			res |= 1 << i
		}
	}
	return res
}

func validateBinaryFlag(field string, value uint8) error {
	if value > 1 {
		return _oops.With("field", field).With("value", value).Errorf("must be 0 or 1")
	}
	return nil
}

func requiredBinaryFlag(field string, value *uint8) (uint8, error) {
	if value == nil {
		return 0, _oops.With("field", field).Errorf("is required")
	}
	if err := validateBinaryFlag(field, *value); err != nil {
		return 0, err
	}
	return *value, nil
}

func validateRailTimetableDate(trainDate, partitionDate string) error {
	if _, err := time.Parse(time.DateOnly, trainDate); err != nil {
		return _oops.With("train_date", trainDate).Wrapf(err, "TrainDate")
	}
	if trainDate != partitionDate {
		return _oops.With("train_date", trainDate).With("partition_date", partitionDate).Errorf("TrainDate does not match partition date")
	}
	return nil
}

func traTrainDate(trainDate, partitionDate string) string {
	if trainDate == "" {
		return partitionDate
	}
	return trainDate
}

func validateTraTimetableHeader(timetable rawTraTimetable, partitionDate string) error {
	trainDate := traTrainDate(timetable.TrainDate, partitionDate)
	if err := validateRailTimetableDate(trainDate, partitionDate); err != nil {
		return err
	}
	info := timetable.DailyTrainInfo
	if err := validateRailTrainInfo(info.TrainNo, info.StartingStationID, info.EndingStationID, info.Direction); err != nil {
		return err
	}
	return nil
}

func validateTraTimetable(timetable rawTraTimetable, partitionDate string) error {
	if err := validateTraTimetableHeader(timetable, partitionDate); err != nil {
		return err
	}
	if err := validateTraTrainFlags(timetable); err != nil {
		return err
	}
	return validateTraStopTimes(timetable)

}

func requireRailStops(count int) error {
	if count == 0 {
		return errors.New("StopTimes must not be empty")
	}
	return nil
}

func validateTraStopTimes(timetable rawTraTimetable) error {
	if err := requireRailStops(len(timetable.StopTimes)); err != nil {
		return err
	}

	return validateTraStops(timetable.StopTimes)
}

func validateTraStops(stops []railStopTime) error {
	for index, stop := range stops {
		if err := validateRailStop(index, stop.StopSequence, stop.StationID, stop.ArrivalTime, stop.DepartureTime); err != nil {
			return err
		}
		if _, err := requiredBinaryFlag("SuspendedFlag", stop.SuspendedFlag); err != nil {
			return _oops.With("index", index).Wrapf(err, "StopTimes element")
		}
	}
	return nil
}

func validateThsrTimetable(timetable rawThsrTimetable, partitionDate string) error {
	if err := validateRailTimetableDate(timetable.TrainDate, partitionDate); err != nil {
		return err
	}
	info := timetable.DailyTrainInfo
	if err := validateRailTrainInfo(info.TrainNo, info.StartingStationID, info.EndingStationID, info.Direction); err != nil {
		return err
	}
	if info.Overnight == nil {
		return errors.New("missing Overnight")
	}
	return validateThsrStopTimes(timetable)
}

func validateThsrStopTimes(timetable rawThsrTimetable) error {
	if err := requireRailStops(len(timetable.StopTimes)); err != nil {
		return err
	}

	for index, stop := range timetable.StopTimes {
		if err := validateRailStop(index, stop.StopSequence, stop.StationID, stop.ArrivalTime, stop.DepartureTime); err != nil {
			return err
		}

	}
	return nil
}

func requireRailFields(fields ...struct{ name, value string }) error {
	for _, field := range fields {
		if strings.TrimSpace(field.value) == "" {
			return errors.New(field.name + " is required")
		}
	}
	return nil
}

func railField(name, value string) struct{ name, value string } {
	return struct{ name, value string }{name, value}
}

func validateRailTrainInfo(trainNo, startStation, endStation string, direction *uint8) error {
	if err := requireRailFields(railField("TrainNo", trainNo), railField("StartingStationID", startStation), railField("EndingStationID", endStation)); err != nil {
		return err
	}
	return validateRailDirection(direction)
}

func validateRailDirection(direction *uint8) error {
	if direction == nil {
		return errors.New("missing Direction")
	}
	if *direction > 1 {
		return _oops.With("direction", *direction).Errorf("invalid Direction, want 0 or 1")
	}
	return nil
}

func validateRailStop(index int, sequence uint8, station, arrival, departure string) error {
	if sequence == 0 {
		return _oops.With("index", index).Errorf("StopTimes element StopSequence must be positive")
	}
	if strings.TrimSpace(station) == "" {
		return _oops.With("index", index).Errorf("StopTimes element StationID is required")
	}
	return validateRailStopClocks(index, arrival, departure)
}

func validateRailStopClocks(index int, arrival, departure string) error {
	if !pipeline.ValidClock(arrival) {
		return _oops.With("index", index).With("arrival_time", arrival).Errorf("StopTimes element ArrivalTime is invalid")
	}
	if !pipeline.ValidClock(departure) {
		return _oops.With("index", index).With("departure_time", departure).Errorf("StopTimes element DepartureTime is invalid")
	}
	return nil
}

func validateTraTrainFlags(timetable rawTraTimetable) error {
	info := timetable.DailyTrainInfo
	for _, flag := range []struct {
		name  string
		value *uint8
	}{
		{"WheelchairFlag", info.WheelchairFlag},
		{"PackageServiceFlag", info.PackageServiceFlag},
		{"DiningFlag", info.DiningFlag},
		{"BikeFlag", info.BikeFlag},
		{"BreastFeedingFlag", info.BreastFeedingFlag},
		{"DailyFlag", info.DailyFlag},
		{"ServiceAddedFlag", info.ServiceAddedFlag},
		{"SuspendedFlag", info.SuspendedFlag},
	} {
		if _, err := requiredBinaryFlag(flag.name, flag.value); err != nil {
			return err
		}
	}
	return nil
}

func LoadTraTimetable(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, date string) error {
	if _, err := time.Parse(time.DateOnly, date); err != nil {
		return _oops.With("date", date).Wrapf(err, "TRA timetable partition date")
	}
	timetables, err := pipeline.DecodeLoadArray[rawTraTimetable](dec, "TRA timetable "+date, func(_ int, timetable rawTraTimetable) error {
		return validateTraTimetable(timetable, date)
	})
	if err != nil {
		return err
	}
	row, err := traTimetableRows(timetables, date)
	if err != nil {
		return err
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key:     "tra_timetable",
		PreExec: []pipeline.CopyUpsertStmt{{SQL: `DELETE FROM tra_timetable WHERE train_date = $1`, Args: []any{date}}},
		CreateSQL: `CREATE TEMP TABLE temp_tra_timetable (
				train_date            date not null,
				trainno               text not null,
				direction             integer,
				starting_station_id   text not null,
				starting_station_name text not null,
				ending_station_id     text not null,
				ending_station_name   text not null,
				train_type_id         text,
				train_type_code       text,
				train_type_name       text,
				tripline              integer,
				stopsequence          smallint,
				stationid             text,
				stationname           text,
				arrivaltime           time,
				departuretime         time,
				mask                  smallint,
				note                  text,
				updated_at            timestamp with time zone
			) ON COMMIT DROP;`,
		TempTable: "temp_tra_timetable",
		CopyCols: []string{
			"train_date", "trainno", "direction", "starting_station_id", "starting_station_name",
			"ending_station_id", "ending_station_name", "train_type_id", "train_type_code", "train_type_name",
			"tripline", "stopsequence", "stationid", "stationname", "arrivaltime", "departuretime", "mask", "note",
		},
		InsertSQL: `INSERT INTO tra_timetable (
			train_date,trainno,direction,starting_station_id,starting_station_name,
			ending_station_id,ending_station_name,train_type_id,train_type_code,train_type_name,
			tripline,stopsequence,stationid,stationname,arrivaltime,departuretime,mask,note,updated_at
		)
		SELECT train_date,trainno,direction,starting_station_id,starting_station_name,
			ending_station_id,ending_station_name,train_type_id,train_type_code,train_type_name,
			tripline,stopsequence,stationid,stationname,arrivaltime,departuretime,mask,note,NOW()
		FROM temp_tra_timetable
		ON CONFLICT (train_date,trainno,stationid) DO UPDATE SET
			direction=EXCLUDED.direction, starting_station_id=EXCLUDED.starting_station_id,
			starting_station_name=EXCLUDED.starting_station_name, ending_station_name=EXCLUDED.ending_station_name,
			ending_station_id=EXCLUDED.ending_station_id, train_type_id=EXCLUDED.train_type_id,
			train_type_code=EXCLUDED.train_type_code, train_type_name=EXCLUDED.train_type_name,
			tripline=EXCLUDED.tripline, stopsequence=EXCLUDED.stopsequence, stationname=EXCLUDED.stationname,
			arrivaltime=EXCLUDED.arrivaltime, departuretime=EXCLUDED.departuretime,
			mask=EXCLUDED.mask, note=EXCLUDED.note, updated_at=NOW();`,
	}, row)
}

func LoadThsrTimetable(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, date string) error {
	if _, err := time.Parse(time.DateOnly, date); err != nil {
		return _oops.With("date", date).Wrapf(err, "THSR timetable partition date")
	}
	timetables, err := pipeline.DecodeLoadArray[rawThsrTimetable](dec, "THSR timetable "+date, func(_ int, timetable rawThsrTimetable) error {
		return validateThsrTimetable(timetable, date)
	})
	if err != nil {
		return err
	}
	row, err := thsrTimetableRows(timetables)
	if err != nil {
		return err
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key:     "thsr_timetable",
		PreExec: []pipeline.CopyUpsertStmt{{SQL: `DELETE FROM thsr_timetable WHERE train_date = $1`, Args: []any{date}}},
		CreateSQL: `CREATE TEMP TABLE temp_thsr_timetable (
				train_date            date not null,
				trainno               text not null,
				direction             integer,
				starting_station_id   text not null,
				starting_station_name text not null,
				ending_station_id     text not null,
				ending_station_name   text not null,
				stopsequence          smallint,
				stationid             text,
				stationname           text,
				arrivaltime           time,
				departuretime         time,
				note                  text,
				overnight             boolean,
				updated_at            timestamp with time zone
			) ON COMMIT DROP;`,
		TempTable: "temp_thsr_timetable",
		CopyCols: []string{
			"train_date", "trainno", "direction", "starting_station_id", "starting_station_name",
			"ending_station_id", "ending_station_name", "stopsequence", "stationid", "stationname",
			"arrivaltime", "departuretime", "note", "overnight",
		},
		InsertSQL: `INSERT INTO thsr_timetable (
			train_date,trainno,direction,starting_station_id,starting_station_name,
			ending_station_id,ending_station_name,stopsequence,stationid,stationname,
			arrivaltime,departuretime,note,overnight,updated_at
		)
		SELECT train_date,trainno,direction,starting_station_id,starting_station_name,
			ending_station_id,ending_station_name,stopsequence,stationid,stationname,
			arrivaltime,departuretime,note,overnight,NOW()
		FROM temp_thsr_timetable
		ON CONFLICT (train_date,trainno,stationid) DO UPDATE SET
			direction=EXCLUDED.direction, starting_station_id=EXCLUDED.starting_station_id,
			starting_station_name=EXCLUDED.starting_station_name, ending_station_name=EXCLUDED.ending_station_name,
			ending_station_id=EXCLUDED.ending_station_id, stopsequence=EXCLUDED.stopsequence,
			stationname=EXCLUDED.stationname, arrivaltime=EXCLUDED.arrivaltime,
			departuretime=EXCLUDED.departuretime, note=EXCLUDED.note, overnight=EXCLUDED.overnight, updated_at=NOW();`,
	}, row)
}

func traStationRows(stations []railStation) ([][]any, error) {
	row := [][]any{}
	seen := make(map[string][]any, len(stations))
	for _, temp := range stations {
		g := fmt.Sprintf("POINT(%.6f %.6f)", temp.StationPosition.PositionLon, temp.StationPosition.PositionLat)
		candidate := []any{
			temp.StationID,
			temp.StationName.ZhTw,
			busmodel.CityToCode[temp.LocationCityCode],
			g,
		}
		if err := pipeline.AppendUniqueLoadRow(&row, seen, temp.StationID, "station", candidate); err != nil {
			return nil, _oops.Wrapf(err, "TRA stations")
		}
	}
	return row, nil
}

func LoadTraStation(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, _ string) error {
	stations, err := pipeline.DecodeLoadArray[railStation](dec, "TRA stations", func(_ int, station railStation) error {
		return validateRailStation(station, false /* requireStationCode */)
	})
	if err != nil {
		return err
	}
	row, err := traStationRows(stations)
	if err != nil {
		return err
	}
	return writeTraStations(ctx, sink, row)
}

func writeTraStations(ctx context.Context, sink pipeline.CopyUpsertSink, row [][]any) error {
	if len(row) > 0 {
		if err := sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
			Key: "tra_station",
			CreateSQL: `CREATE TEMP TABLE temp_tra (
					station_id text,
					name text,
					city text,
					geom text
				) ON COMMIT DROP;`,
			TempTable: "temp_tra",
			CopyCols:  []string{"station_id", "name", "city", "geom"},
			InsertSQL: `INSERT INTO tra_stations (
					station_id,
					name,
					city,
					geom,
					updated_at
				)
				SELECT station_id, name, city, ST_GeomFromText(geom, 4326),NOW()
				FROM temp_tra
				ON CONFLICT (station_id) DO UPDATE SET name = EXCLUDED.name, city = EXCLUDED.city, geom = EXCLUDED.geom,updated_at = NOW();`,
		}, row); err != nil {
			return err
		}
	} else {
		zap.S().Infow("complete",
			"component", "rail",
			"action", "tra_station",
			"event", "complete",
			"reason", "no_data",
		)
	}
	zap.S().Infow("complete", "component", "rail", "action", "tra_station", "event", "complete")
	return nil
}

// LoadThsrStation upserts THSR stations into thsr_stations via one temp-table
// COPY transaction. It consumes an already-opened decoder and rejects an
// invalid or ambiguous payload before opening the transaction.
func thsrStationRows(stations []railStation) ([][]any, error) {
	rows := make([][]any, 0, len(stations))
	seen := make(map[string][]any, len(stations))
	for _, station := range stations {
		g := fmt.Sprintf("POINT(%.6f %.6f)", station.StationPosition.PositionLon, station.StationPosition.PositionLat)
		candidate := []any{
			station.StationID,
			station.StationName.ZhTw,
			busmodel.CityToCode[station.LocationCityCode],
			g,
			station.StationCode,
		}
		if err := pipeline.AppendUniqueLoadRow(&rows, seen, station.StationID, "station", candidate); err != nil {
			return nil, _oops.Wrapf(err, "THSR stations")
		}
	}
	return rows, nil
}

func LoadThsrStation(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, _ string) error {
	stations, err := pipeline.DecodeLoadArray[railStation](dec, "THSR stations", func(_ int, station railStation) error {
		return validateRailStation(station, true /* requireStationCode */)
	})
	if err != nil {
		return err
	}
	if len(stations) == 0 {
		return nil
	}
	rows, err := thsrStationRows(stations)
	if err != nil {
		return err
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "thsr_station",
		CreateSQL: `CREATE TEMP TABLE temp_thsr_station (
			station_id text, name text, city text, geom text, stationcode text
		) ON COMMIT DROP`,
		TempTable: "temp_thsr_station",
		CopyCols:  []string{"station_id", "name", "city", "geom", "stationcode"},
		InsertSQL: `INSERT INTO thsr_stations (
			station_id, name, city, geom, stationcode, updated_at
		)
		SELECT station_id, name, city, ST_GeomFromText(geom, 4326), stationcode, NOW()
		FROM temp_thsr_station
		ON CONFLICT (station_id) DO UPDATE SET
			name = EXCLUDED.name, city = EXCLUDED.city, geom = EXCLUDED.geom,
			stationcode = EXCLUDED.stationcode, updated_at = NOW()`,
	}, rows)
}

func validateRailStation(station railStation, requireStationCode bool) error {
	if err := requireRailFields(railField("StationID", station.StationID), railField("LocationCityCode", station.LocationCityCode)); err != nil {
		return err
	}
	if _, ok := busmodel.CityToCode[station.LocationCityCode]; !ok {
		return _oops.With("location_city_code", station.LocationCityCode).Errorf("LocationCityCode is unknown")
	}
	return validateRailStationPosition(station, requireStationCode)
}

func validateRailStationCode(code string, required bool) error {
	if required && strings.TrimSpace(code) == "" {
		return errors.New("StationCode is required")
	}
	return nil
}

func validateRailStationPosition(station railStation, requireStationCode bool) error {
	if err := validateRailStationCode(station.StationCode, requireStationCode); err != nil {
		return err
	}
	if !pipeline.ValidPosition(station.StationPosition.PositionLon, station.StationPosition.PositionLat) {
		return _oops.With("position_lon", station.StationPosition.PositionLon).With("position_lat", station.StationPosition.PositionLat).Errorf("position is invalid: lon= lat=")
	}
	return nil
}

func parseRailStopClocks(mode, date, train string, stop railStopTime) (time.Time, time.Time, error) {
	at, err := time.Parse("15:04", stop.ArrivalTime)
	if err != nil {
		return time.Time{}, time.Time{}, _oops.With("date", date).With("train_no", train).With("station_id", stop.StationID).With("arrival_time", stop.ArrivalTime).Wrapf(err, "%s timetable train station ArrivalTime", mode)
	}
	dt, err := time.Parse("15:04", stop.DepartureTime)
	if err != nil {
		return time.Time{}, time.Time{}, _oops.With("date", date).With("train_no", train).With("station_id", stop.StationID).With("departure_time", stop.DepartureTime).Wrapf(err, "%s timetable train station DepartureTime", mode)
	}
	return at, dt, nil
}

func appendThsrTrainRows(row *[][]any, seen map[string][]any, temp rawThsrTimetable) error {
	for _, stop := range temp.StopTimes {
		at, dt, err := parseRailStopClocks("THSR", temp.TrainDate, temp.DailyTrainInfo.TrainNo, stop)
		if err != nil {
			return err
		}
		candidate := []any{
			temp.TrainDate,
			temp.DailyTrainInfo.TrainNo,
			*temp.DailyTrainInfo.Direction,
			temp.DailyTrainInfo.StartingStationID,
			temp.DailyTrainInfo.StartingStationName.ZhTw,
			temp.DailyTrainInfo.EndingStationID,
			temp.DailyTrainInfo.EndingStationName.ZhTw,
			stop.StopSequence,
			stop.StationID,
			stop.StationName.ZhTw,
			at,
			dt,
			temp.DailyTrainInfo.Note.ZhTw,
			*temp.DailyTrainInfo.Overnight,
		}
		key := temp.TrainDate + "\x00" + temp.DailyTrainInfo.TrainNo + "\x00" + stop.StationID
		if err := pipeline.AppendUniqueLoadRow(row, seen, key, "timetable", candidate); err != nil {
			return _oops.With("date", temp.TrainDate).Wrapf(err, "THSR timetable")
		}
	}
	return nil
}

func thsrTimetableRows(timetables []rawThsrTimetable) ([][]any, error) {
	row := [][]any{}
	seen := make(map[string][]any)
	for _, temp := range timetables {
		if err := appendThsrTrainRows(&row, seen, temp); err != nil {
			return nil, err
		}
	}
	return row, nil
}

func traFareRows(fares []traFare) ([][]any, error) {
	row := [][]any{}
	seen := make(map[string][]any)
	for _, temp := range fares {
		for _, t1 := range temp.Fares {
			candidate := []any{temp.OriginStationID, temp.DestinationStationID, t1.TicketType, t1.Price}
			key := temp.OriginStationID + "\x00" + temp.DestinationStationID + "\x00" + t1.TicketType
			if err := pipeline.AppendUniqueLoadRow(&row, seen, key, "fare", candidate); err != nil {
				return nil, _oops.Wrapf(err, "TRA fares")
			}
		}
	}
	return row, nil
}

func LoadTraFare(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, _ string) error {
	fares, err := pipeline.DecodeLoadArray[traFare](dec, "TRA fares", validateTraFare)
	if err != nil {
		return err
	}
	if len(fares) == 0 {
		return nil
	}
	row, err := traFareRows(fares)
	if err != nil {
		return err
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "tra_fare",
		CreateSQL: `CREATE TEMP TABLE temp_tra_fare (
				origin_station_id text,
				destination_station_id text,
				ticket_type text,
				price int
			) ON COMMIT DROP;`,
		TempTable: "temp_tra_fare",
		CopyCols:  []string{"origin_station_id", "destination_station_id", "ticket_type", "price"},
		InsertSQL: `INSERT INTO tra_fares (
				origin_station_id,
				destination_station_id,
				ticket_type,
				price,
				updated_at
			)
			SELECT origin_station_id, destination_station_id, ticket_type, price, NOW() FROM temp_tra_fare
			ON CONFLICT (origin_station_id, destination_station_id, ticket_type)
			DO UPDATE SET price = EXCLUDED.price, updated_at = NOW()`,
	}, row)
}

func thsrFareRows(fares []thsrFare) ([][]any, error) {
	row := [][]any{}
	seen := make(map[string][]any)
	for _, temp := range fares {
		for _, t1 := range temp.Fares {
			candidate := []any{temp.OriginStationID, temp.DestinationStationID, t1.TicketType, t1.FareClass, t1.CabinClass, t1.Price}
			key := fmt.Sprintf("%s\x00%s\x00%d\x00%d\x00%d", temp.OriginStationID, temp.DestinationStationID, t1.TicketType, t1.FareClass, t1.CabinClass)
			if err := pipeline.AppendUniqueLoadRow(&row, seen, key, "fare", candidate); err != nil {
				return nil, _oops.Wrapf(err, "THSR fares")
			}
		}
	}
	return row, nil
}

func LoadThsrFare(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, _ string) error {
	fares, err := pipeline.DecodeLoadArray[thsrFare](dec, "THSR fares", validateThsrFare)
	if err != nil {
		return err
	}
	if len(fares) == 0 {
		return nil
	}
	row, err := thsrFareRows(fares)
	if err != nil {
		return err
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "thsr_fare",
		CreateSQL: `CREATE TEMP TABLE temp_thsr (
				origin_station_id text,
				destination_station_id text,
				ticket_type smallint,
				fare_class smallint,
				cabin_class smallint,
				price int
			) ON COMMIT DROP;`,
		TempTable: "temp_thsr",
		CopyCols:  []string{"origin_station_id", "destination_station_id", "ticket_type", "fare_class", "cabin_class", "price"},
		InsertSQL: `INSERT INTO thsr_fares (
				origin_station_id,
				destination_station_id,
				ticket_type,
				fare_class,
				cabin_class,
				price,
				updated_at
			)
			SELECT origin_station_id, destination_station_id, ticket_type, fare_class,cabin_class,price, NOW() FROM temp_thsr
			ON CONFLICT (origin_station_id, destination_station_id, ticket_type, fare_class, cabin_class)
			DO UPDATE SET price = EXCLUDED.price, updated_at = NOW()`,
	}, row)
}

// TraEta refreshes TRA realtime data into Redis on the 2-minute cron: per-train
// delays as hash tra:delay plus a published tra:delay:all snapshot, all with a
// 3-minute TTL so stale data expires.

// On a 304, pipeline.BoundFetch has already re-armed the delay keys' TTL.

func validateTraFare(_ int, fare traFare) error {
	if err := validateRailFareHeader(fare.OriginStationID, fare.DestinationStationID, len(fare.Fares)); err != nil {
		return err
	}
	return validateTraFareItems(fare)
}

func validateTraFareItems(fare traFare) error {
	for index, item := range fare.Fares {
		if err := validateTraFareItem(index, item.TicketType, item.Price); err != nil {
			return err
		}
	}
	return nil
}

func validateTraFareItem(index int, ticketType string, price int32) error {
	if strings.TrimSpace(ticketType) == "" {
		return _oops.With("index", index).Errorf("fares element missing TicketType")
	}
	if price < 0 {
		return _oops.With("index", index).Errorf("fares element Price must be non-negative")
	}
	return nil
}

func validateThsrFare(_ int, fare thsrFare) error {
	if err := validateRailFareHeader(fare.OriginStationID, fare.DestinationStationID, len(fare.Fares)); err != nil {
		return err
	}
	return validateThsrFareItems(fare)
}

func validateThsrFareItems(fare thsrFare) error {
	for index, item := range fare.Fares {
		if err := validateThsrFareItem(index, item.TicketType, item.FareClass, item.CabinClass); err != nil {
			return err
		}
	}
	return nil
}

func validateRailFareHeader(origin, destination string, count int) error {
	if err := requireRailFields(railField("OriginStationID", origin), railField("DestinationStationID", destination)); err != nil {
		return err
	}
	if count == 0 {
		return errors.New("missing Fares")
	}
	return nil
}

func validateThsrFareItem(index int, ticketType, fareClass, cabinClass uint8) error {
	if ticketType == 0 {
		return _oops.With("index", index).Errorf("fares element missing TicketType")
	}
	if fareClass == 0 {
		return _oops.With("index", index).Errorf("fares element missing FareClass")
	}
	if cabinClass == 0 {
		return _oops.With("index", index).Errorf("fares element missing CabinClass")
	}
	return nil
}

func appendTraTrainRows(row *[][]any, seen map[string][]any, temp rawTraTimetable, date string) error {
	for _, stop := range temp.StopTimes {
		at, dt, err := parseRailStopClocks("TRA", date, temp.DailyTrainInfo.TrainNo, stop)
		if err != nil {
			return err
		}
		candidate := []any{
			temp.TrainDate,
			temp.DailyTrainInfo.TrainNo,
			*temp.DailyTrainInfo.Direction,
			temp.DailyTrainInfo.StartingStationID,
			temp.DailyTrainInfo.StartingStationName.ZhTw,
			temp.DailyTrainInfo.EndingStationID,
			temp.DailyTrainInfo.EndingStationName.ZhTw,
			temp.DailyTrainInfo.TrainTypeID,
			temp.DailyTrainInfo.TrainTypeCode,
			temp.DailyTrainInfo.TrainTypeName.ZhTw,
			temp.DailyTrainInfo.TripLine,
			stop.StopSequence,
			stop.StationID,
			stop.StationName.ZhTw,
			at,
			dt,
			railMask(railTrainFlags{
				wheel:     *temp.DailyTrainInfo.WheelchairFlag,
				pack:      *temp.DailyTrainInfo.PackageServiceFlag,
				dining:    *temp.DailyTrainInfo.DiningFlag,
				bike:      *temp.DailyTrainInfo.BikeFlag,
				breast:    *temp.DailyTrainInfo.BreastFeedingFlag,
				daily:     *temp.DailyTrainInfo.DailyFlag,
				service:   *temp.DailyTrainInfo.ServiceAddedFlag,
				suspended: *temp.DailyTrainInfo.SuspendedFlag | *stop.SuspendedFlag,
			}),
			temp.DailyTrainInfo.Note.ZhTw,
		}
		key := temp.TrainDate + "\x00" + temp.DailyTrainInfo.TrainNo + "\x00" + stop.StationID
		if err := pipeline.AppendUniqueLoadRow(row, seen, key, "timetable", candidate); err != nil {
			return _oops.With("date", date).Wrapf(err, "TRA timetable")
		}
	}
	return nil
}

func traTimetableRows(timetables []rawTraTimetable, date string) ([][]any, error) {
	row := [][]any{}
	seen := make(map[string][]any)
	for _, temp := range timetables {
		if temp.TrainDate == "" {
			temp.TrainDate = date
		}
		if err := appendTraTrainRows(&row, seen, temp, date); err != nil {
			return nil, err
		}
	}
	return row, nil
}
