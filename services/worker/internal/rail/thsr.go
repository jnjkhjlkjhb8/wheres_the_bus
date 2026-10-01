package rail

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/pipeline"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

type rawThsrAvailableSeatStatus struct {
	TrainDate string `json:"TrainDate"`
	Items     []struct {
		TrainNo              string `json:"TrainNo"`
		OriginStationID      string `json:"OriginStationID"`
		DestinationStationID string `json:"DestinationStationID"`
		StandardSeatStatus   string `json:"StandardSeatStatus"`
		BusinessSeatStatus   string `json:"BusinessSeatStatus"`
	} `json:"Items"`
}

func ThsrAvailableSeats(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
	date := time.Now().In(pipeline.Taipei).Format(time.DateOnly)
	zap.S().Infow("start", "component", "thsr_seats", "action", "thsr_seats", "event", "start", "date", date)
	result, err := fetch(ctx, fmt.Sprintf("/v2/Rail/THSR/AvailableSeatStatus/Train/OD/TrainDate/%s", date), "thsr_availableseats")
	if err != nil {
		return _oops.With("date", date).Wrapf(err, "fetch THSR available seats")
	}
	if !result.Modified {
		// A 304 has already re-armed the cached snapshots' TTL via pipeline.BoundFetch.
		zap.S().Warnw("skip",
			"component", "thsr_seats",
			"action", "thsr_seats",
			"event", "skip",
			"reason", "no_update",
		)
		return nil
	}
	err = pipeline.CommitTDXFetch(result, func(dec *json.Decoder) error {
		row := make(map[string]*models.ThsrAvailableSeats)
		if decErr := pipeline.DecodeLiveItems(dec, func(temp rawThsrAvailableSeatStatus) error {
			for _, stop := range temp.Items {
				if row[stop.TrainNo] == nil {
					row[stop.TrainNo] = &models.ThsrAvailableSeats{}
				}
				row[stop.TrainNo].Segments = append(row[stop.TrainNo].Segments, &models.ThsrSeatSegment{
					OriginStationId:      stop.OriginStationID,
					DestinationStationId: stop.DestinationStationID,
					StandardSeatStatus:   stop.StandardSeatStatus,
					BusinessSeatStatus:   stop.BusinessSeatStatus,
				})
			}
			return nil
		}); decErr != nil {
			return decErr
		}
		channel := shared.ThsrSeatsPattern(date)
		pipe := sink.Pipe()
		count := 0
		for trainNo, seats := range row {
			pb, err := proto.Marshal(seats)
			if err != nil {
				return err
			}
			pipe.Set(shared.ThsrSeatsKey(date, trainNo), pb, pipeline.ThsrSeatsLiveTTL)
			pipe.Publish(channel, string(pb))
			count++
		}
		if err := pipe.Exec(ctx); err != nil {
			return err
		}
		zap.S().Infow("complete",
			"component", "thsr_seats",
			"action", "thsr_seats",
			"event", "complete",
			"train_count", count,
		)
		return nil
	})
	if err != nil {
		return _oops.With("date", date).Wrapf(err, "process THSR available seats")
	}
	return nil
}
