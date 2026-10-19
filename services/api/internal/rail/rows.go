package rail

import (
	"context"
	"github.com/jackc/pgx/v5"
	"google.golang.org/protobuf/proto"
)

func queryRailRows[T any](ctx context.Context, db railDB, sql string, args ...any) ([]*T, error) {
	rows, err := db.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToAddrOfStructByName[T])
}

func resolveRailJourney(ctx context.Context, db railDB, table, start, end string) (string, string, error) {
	start, err := resolveRailStationID(ctx, db, table, start)
	if err != nil {
		return "", "", err
	}
	end, err = resolveRailStationID(ctx, db, table, end)
	return start, end, err
}

func marshalRailPayload(message proto.Message, count int) ([]byte, int, error) {
	data, err := proto.Marshal(message)
	if err != nil {
		return nil, 0, err
	}
	return data, count, nil
}

func forwardRailTrip(station, end string, sequence, originSequence int, known bool) bool {
	return station == end && known && sequence > originSequence
}
