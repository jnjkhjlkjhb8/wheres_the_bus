package rail

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
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
type traDelay struct {
	TrainNo     string `json:"TrainNo"`
	StationID   string `json:"StationID"`
	StationName struct {
		ZhTw string `json:"Zh_tw"`
	} `json:"StationName"`
	DelayTime     uint16 `json:"DelayTime"`
	SrcUpdateTime string `json:"SrcUpdateTime"`
}

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
	StopTimes []struct {
		StopSequence uint8  `json:"StopSequence"`
		StationID    string `json:"StationID"`
		StationName  struct {
			ZhTw string `json:"Zh_tw"`
		} `json:"StationName"`
		ArrivalTime   string `json:"ArrivalTime"`
		DepartureTime string `json:"DepartureTime"`
		SuspendedFlag *uint8 `json:"SuspendedFlag"`
	} `json:"StopTimes"`
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
	StopTimes []struct {
		StopSequence uint8  `json:"StopSequence"`
		StationID    string `json:"StationID"`
		StationName  struct {
			ZhTw string `json:"Zh_tw"`
		} `json:"StationName"`
		ArrivalTime   string `json:"ArrivalTime"`
		DepartureTime string `json:"DepartureTime"`
	} `json:"StopTimes"`
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

func validateTraTimetable(timetable rawTraTimetable, partitionDate string) error {
	trainDate := timetable.TrainDate
	if trainDate == "" {
		trainDate = partitionDate
	}
	if _, err := time.Parse(time.DateOnly, trainDate); err != nil {
		return _oops.With("train_date", trainDate).Wrapf(err, "TrainDate")
	}
	if trainDate != partitionDate {
		return _oops.With("train_date", trainDate).With("partition_date", partitionDate).Errorf("TrainDate does not match partition date")
	}
	info := timetable.DailyTrainInfo
	if strings.TrimSpace(info.TrainNo) == "" {
		return errors.New("TrainNo is required")
	}
	if strings.TrimSpace(info.StartingStationID) == "" {
		return errors.New("StartingStationID is required")
	}
	if strings.TrimSpace(info.EndingStationID) == "" {
		return errors.New("EndingStationID is required")
	}
	if info.Direction == nil {
		return errors.New("missing Direction")
	}
	if *info.Direction > 1 {
		return _oops.With("direction", *info.Direction).Errorf("invalid Direction, want 0 or 1")
	}
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
	if len(timetable.StopTimes) == 0 {
		return errors.New("StopTimes must not be empty")
	}
	for index, stop := range timetable.StopTimes {
		if stop.StopSequence == 0 {
			return _oops.With("index", index).Errorf("StopTimes element StopSequence must be positive")
		}
		if strings.TrimSpace(stop.StationID) == "" {
			return _oops.With("index", index).Errorf("StopTimes element StationID is required")
		}
		if !pipeline.ValidClock(stop.ArrivalTime) {
			return _oops.With("index", index).With("arrival_time", stop.ArrivalTime).Errorf("StopTimes element ArrivalTime is invalid")
		}
		if !pipeline.ValidClock(stop.DepartureTime) {
			return _oops.With("index", index).With("departure_time", stop.DepartureTime).Errorf("StopTimes element DepartureTime is invalid")
		}
		if _, err := requiredBinaryFlag("SuspendedFlag", stop.SuspendedFlag); err != nil {
			return _oops.With("index", index).Wrapf(err, "StopTimes element")
		}
	}
	return nil
}

func validateThsrTimetable(timetable rawThsrTimetable, partitionDate string) error {
	if _, err := time.Parse(time.DateOnly, timetable.TrainDate); err != nil {
		return _oops.With("train_date", timetable.TrainDate).Wrapf(err, "TrainDate")
	}
	if timetable.TrainDate != partitionDate {
		return _oops.With("train_date", timetable.TrainDate).With("partition_date", partitionDate).Errorf("TrainDate does not match partition date")
	}
	info := timetable.DailyTrainInfo
	if strings.TrimSpace(info.TrainNo) == "" {
		return errors.New("TrainNo is required")
	}
	if strings.TrimSpace(info.StartingStationID) == "" {
		return errors.New("StartingStationID is required")
	}
	if strings.TrimSpace(info.EndingStationID) == "" {
		return errors.New("EndingStationID is required")
	}
	if info.Direction == nil {
		return errors.New("missing Direction")
	}
	if *info.Direction > 1 {
		return _oops.With("direction", *info.Direction).Errorf("invalid Direction, want 0 or 1")
	}
	if info.Overnight == nil {
		return errors.New("missing Overnight")
	}
	if len(timetable.StopTimes) == 0 {
		return errors.New("StopTimes must not be empty")
	}
	for index, stop := range timetable.StopTimes {
		if stop.StopSequence == 0 {
			return _oops.With("index", index).Errorf("StopTimes element StopSequence must be positive")
		}
		if strings.TrimSpace(stop.StationID) == "" {
			return _oops.With("index", index).Errorf("StopTimes element StationID is required")
		}
		if !pipeline.ValidClock(stop.ArrivalTime) {
			return _oops.With("index", index).With("arrival_time", stop.ArrivalTime).Errorf("StopTimes element ArrivalTime is invalid")
		}
		if !pipeline.ValidClock(stop.DepartureTime) {
			return _oops.With("index", index).With("departure_time", stop.DepartureTime).Errorf("StopTimes element DepartureTime is invalid")
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
	row := [][]any{}
	seen := make(map[string][]any)
	for _, temp := range timetables {
		if temp.TrainDate == "" {
			temp.TrainDate = date
		}
		for _, stop := range temp.StopTimes {
			at, err := time.Parse("15:04", stop.ArrivalTime)
			if err != nil {
				return _oops.With("date", date).With("train_no", temp.DailyTrainInfo.TrainNo).With("station_id", stop.StationID).With("arrival_time", stop.ArrivalTime).Wrapf(err, "TRA timetable train station ArrivalTime")
			}
			dt, err := time.Parse("15:04", stop.DepartureTime)
			if err != nil {
				return _oops.With("date", date).With("train_no", temp.DailyTrainInfo.TrainNo).With("station_id", stop.StationID).With("departure_time", stop.DepartureTime).Wrapf(err, "TRA timetable train station DepartureTime")
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
			if err := pipeline.AppendUniqueLoadRow(&row, seen, key, "timetable", candidate); err != nil {
				return _oops.With("date", date).Wrapf(err, "TRA timetable")
			}
		}
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
	row := [][]any{}
	seen := make(map[string][]any)
	for _, temp := range timetables {
		for _, stop := range temp.StopTimes {
			at, err := time.Parse("15:04", stop.ArrivalTime)
			if err != nil {
				return _oops.With("date", date).With("train_no", temp.DailyTrainInfo.TrainNo).With("station_id", stop.StationID).With("arrival_time", stop.ArrivalTime).Wrapf(err, "THSR timetable train station ArrivalTime")
			}
			dt, err := time.Parse("15:04", stop.DepartureTime)
			if err != nil {
				return _oops.With("date", date).With("train_no", temp.DailyTrainInfo.TrainNo).With("station_id", stop.StationID).With("departure_time", stop.DepartureTime).Wrapf(err, "THSR timetable train station DepartureTime")
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
			if err := pipeline.AppendUniqueLoadRow(&row, seen, key, "timetable", candidate); err != nil {
				return _oops.With("date", date).Wrapf(err, "THSR timetable")
			}
		}
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

func LoadTraStation(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, _ string) error {
	stations, err := pipeline.DecodeLoadArray[railStation](dec, "TRA stations", func(_ int, station railStation) error {
		return validateRailStation(station, false /* requireStationCode */)
	})
	if err != nil {
		return err
	}
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
			return _oops.Wrapf(err, "TRA stations")
		}
	}
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
			return _oops.Wrapf(err, "THSR stations")
		}
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
	if strings.TrimSpace(station.StationID) == "" {
		return errors.New("StationID is required")
	}
	if strings.TrimSpace(station.LocationCityCode) == "" {
		return errors.New("LocationCityCode is required")
	}
	if _, ok := busmodel.CityToCode[station.LocationCityCode]; !ok {
		return _oops.With("location_city_code", station.LocationCityCode).Errorf("LocationCityCode is unknown")
	}
	if requireStationCode && strings.TrimSpace(station.StationCode) == "" {
		return errors.New("StationCode is required")
	}
	if !pipeline.ValidPosition(station.StationPosition.PositionLon, station.StationPosition.PositionLat) {
		return _oops.With("position_lon", station.StationPosition.PositionLon).With("position_lat", station.StationPosition.PositionLat).Errorf("position is invalid: lon= lat=")
	}
	return nil
}

func LoadTraFare(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, _ string) error {
	fares, err := pipeline.DecodeLoadArray[traFare](dec, "TRA fares", func(_ int, fare traFare) error {
		if strings.TrimSpace(fare.OriginStationID) == "" {
			return errors.New("OriginStationID is required")
		}
		if strings.TrimSpace(fare.DestinationStationID) == "" {
			return errors.New("DestinationStationID is required")
		}
		if len(fare.Fares) == 0 {
			return errors.New("missing Fares")
		}
		for index, item := range fare.Fares {
			if strings.TrimSpace(item.TicketType) == "" {
				return _oops.With("index", index).Errorf("fares element missing TicketType")
			}
			if item.Price < 0 {
				return _oops.With("index", index).Errorf("fares element Price must be non-negative")
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	if len(fares) == 0 {
		return nil
	}
	row := [][]any{}
	seen := make(map[string][]any)
	for _, temp := range fares {
		for _, t1 := range temp.Fares {
			candidate := []any{temp.OriginStationID, temp.DestinationStationID, t1.TicketType, t1.Price}
			key := temp.OriginStationID + "\x00" + temp.DestinationStationID + "\x00" + t1.TicketType
			if err := pipeline.AppendUniqueLoadRow(&row, seen, key, "fare", candidate); err != nil {
				return _oops.Wrapf(err, "TRA fares")
			}
		}
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

func LoadThsrFare(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, _ string) error {
	fares, err := pipeline.DecodeLoadArray[thsrFare](dec, "THSR fares", func(_ int, fare thsrFare) error {
		if strings.TrimSpace(fare.OriginStationID) == "" {
			return errors.New("OriginStationID is required")
		}
		if strings.TrimSpace(fare.DestinationStationID) == "" {
			return errors.New("DestinationStationID is required")
		}
		if len(fare.Fares) == 0 {
			return errors.New("missing Fares")
		}
		for index, item := range fare.Fares {
			if item.TicketType == 0 {
				return _oops.With("index", index).Errorf("fares element missing TicketType")
			}
			if item.FareClass == 0 {
				return _oops.With("index", index).Errorf("fares element missing FareClass")
			}
			if item.CabinClass == 0 {
				return _oops.With("index", index).Errorf("fares element missing CabinClass")
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	if len(fares) == 0 {
		return nil
	}
	row := [][]any{}
	seen := make(map[string][]any)
	for _, temp := range fares {
		for _, t1 := range temp.Fares {
			candidate := []any{temp.OriginStationID, temp.DestinationStationID, t1.TicketType, t1.FareClass, t1.CabinClass, t1.Price}
			key := fmt.Sprintf("%s\x00%s\x00%d\x00%d\x00%d", temp.OriginStationID, temp.DestinationStationID, t1.TicketType, t1.FareClass, t1.CabinClass)
			if err := pipeline.AppendUniqueLoadRow(&row, seen, key, "fare", candidate); err != nil {
				return _oops.Wrapf(err, "THSR fares")
			}
		}
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
func TraEta(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
	zap.S().Infow("start", "component", "tra_eta", "action", "tra_eta", "event", "start")
	result, err := fetch(ctx, "/v2/Rail/TRA/LiveTrainDelay", "tra_delay")
	if err != nil {
		return _oops.Wrapf(err, "fetch TRA live train delay")
	}
	if !result.Modified {
		// On a 304, pipeline.BoundFetch has already re-armed the delay keys' TTL.
		zap.S().Warnw("skip delay",
			"component", "tra_eta",
			"action", "tra_eta",
			"event", "skip_delay",
			"reason", "no_update",
		)
		return nil
	}
	err = pipeline.CommitTDXFetch(result, func(dec *json.Decoder) error {
		data := &models.TraDelays{
			Delay: make(map[string]int32),
		}
		count := 0
		pipe := sink.Pipe()
		if decErr := pipeline.DecodeLiveItems(dec, func(temp traDelay) error {
			count++
			delay := int32(temp.DelayTime)
			data.Delay[temp.TrainNo] = delay
			pipe.HSet(shared.TraDelayHashKey, temp.TrainNo, temp.DelayTime)
			if temp.StationID != "" {
				pipe.HSet(shared.TraDelayStationKey, temp.TrainNo, temp.StationID)
			}
			trainBytes, err := proto.Marshal(&models.TraDelays{Delay: map[string]int32{temp.TrainNo: delay}})
			if err != nil {
				return _oops.With("train_no", temp.TrainNo).Wrapf(err, "marshal TRA delay for train")
			}
			trainKey := shared.TraDelayTrainChannel(temp.TrainNo)
			pipe.Set(trainKey, trainBytes, pipeline.TraLiveTTL)
			pipe.Publish(trainKey, trainBytes)
			return nil
		}); decErr != nil {
			return decErr
		}
		bytes, err := proto.Marshal(data)
		if err != nil {
			return err
		}
		pipe.Set(shared.TraDelayAllKey, bytes, pipeline.TraLiveTTL)
		pipe.Publish(shared.TraDelayAllKey, string(bytes))
		pipe.Expire(shared.TraDelayHashKey, pipeline.TraLiveTTL)
		pipe.Expire(shared.TraDelayStationKey, pipeline.TraLiveTTL)
		if err := pipe.Exec(ctx); err != nil {
			return _oops.Wrapf(err, "publish TRA delay snapshot")
		}
		zap.S().Infow("delay redis success",
			"component", "tra_eta",
			"action", "tra_eta",
			"event", "delay_redis_success",
			"count", count,
		)
		return nil
	})
	if err != nil {
		return _oops.Wrapf(err, "process TRA live train delay")
	}
	zap.S().Infow("complete", "component", "tra_eta", "action", "tra_eta", "event", "complete")
	return nil
}
