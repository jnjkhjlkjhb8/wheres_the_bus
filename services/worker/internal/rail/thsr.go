package rail

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
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

// ThsrAvailableSeats refreshes today's THSR seat availability while someone
// watches it.
func ThsrAvailableSeats(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink, guard *pipeline.LiveFetchGuard) error {
	release, ok := pipeline.ClaimLiveDemand(ctx, sink, guard, "thsr_seats", "THSR")
	if !ok {
		return nil
	}
	defer release()
	return fetchThsrSeats(ctx, fetch, sink)
}

func fetchThsrSeats(ctx context.Context, fetch pipeline.BoundFetch, sink pipeline.LiveSink) error {
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
	return commitThsrSeats(ctx, sink, result, date)
}

func commitThsrSeats(ctx context.Context, sink pipeline.LiveSink, result *shared.TDXFetch, date string) error {
	err := pipeline.CommitTDXFetch(result, func(dec *json.Decoder) error {
		return publishThsrSeats(ctx, sink, dec, date)
	})
	if err != nil {
		return _oops.With("date", date).Wrapf(err, "process THSR available seats")
	}
	return nil
}

func publishThsrSeats(ctx context.Context, sink pipeline.LiveSink, dec *json.Decoder, date string) error {
	row, err := readThsrSeats(dec)
	if err != nil {
		return err
	}
	return publishThsrSeatRows(ctx, sink, row, date)
}

func readThsrSeats(dec *json.Decoder) (map[string]*models.ThsrAvailableSeats, error) {
	row := make(map[string]*models.ThsrAvailableSeats)
	err := pipeline.DecodeLiveItems(dec, func(temp rawThsrAvailableSeatStatus) error {
		appendThsrSeats(row, temp)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return row, nil
}

func appendThsrSeats(row map[string]*models.ThsrAvailableSeats, temp rawThsrAvailableSeatStatus) {
	for _, stop := range temp.Items {
		if row[stop.TrainNo] == nil {
			row[stop.TrainNo] = &models.ThsrAvailableSeats{}
		}
		row[stop.TrainNo].Segments = append(row[stop.TrainNo].Segments, &models.ThsrSeatSegment{OriginStationId: stop.OriginStationID, DestinationStationId: stop.DestinationStationID, StandardSeatStatus: stop.StandardSeatStatus, BusinessSeatStatus: stop.BusinessSeatStatus})
	}
}

func publishThsrSeatRows(ctx context.Context, sink pipeline.LiveSink, row map[string]*models.ThsrAvailableSeats, date string) error {
	channel := shared.ThsrSeatsPattern(date)
	pipe := sink.Pipe()
	count := 0
	for trainNo, seats := range row {
		if err := queueThsrTrain(pipe, channel, date, trainNo, seats); err != nil {
			return err
		}
		count++
	}
	return commitThsrSnapshot(ctx, pipe, count)
}

func queueThsrTrain(pipe pipeline.LivePipe, channel, date, trainNo string, seats *models.ThsrAvailableSeats) error {
	pb, err := proto.Marshal(seats)
	if err != nil {
		return err
	}
	pipe.Set(shared.ThsrSeatsKey(date, trainNo), pb, pipeline.ThsrSeatsLiveTTL)
	pipe.Publish(channel, string(pb))
	return nil
}

func commitThsrSnapshot(ctx context.Context, pipe pipeline.LivePipe, count int) error {
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
}
