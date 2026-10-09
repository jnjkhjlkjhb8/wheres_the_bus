package rail

import (
	"context"
	"encoding/json"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// railStation decodes a TDX TRA/THSR Station element, used for both the TRA and
// THSR static station tables.

// traFare decodes a TDX TRA/ODFare element: fares between a station pair by
// ticket type.

// thsrFare decodes a TDX THSR/ODFare element: fares between a station pair,
// further split by fare class and cabin class.

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

// rawThsrTimetable decodes a TDX THSR/DailyTimetable element: one high-speed
// train's info and stop times for a service date. Overnight marks a train that
// crosses midnight.

// railTrainFlags holds a TRA train's amenity/service boolean flags (1 = set)
// before they are packed into a single bitmask by railMask.

// railMask packs a TRA train's amenity flags into a uint16 bitmask (bit 0 =
// wheelchair through bit 7 = suspended, in struct field order) for compact
// storage in tra_timetable.mask.

/* requireStationCode */

// LoadThsrStation upserts THSR stations into thsr_stations via one temp-table
// COPY transaction. It consumes an already-opened decoder and rejects an
// invalid or ambiguous payload before opening the transaction.

/* requireStationCode */

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
