package rail

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
	"go.uber.org/zap"
)

// railShapeRow is one TDX Rail/Shape element (TRA, THSR, or metro): the raw
// WKT geometry for one line, plus the identity/name fields carried alongside
// it. LineNo is absent from the THSR payload, so it is decoded but unused.
type railShapeRow struct {
	LineNo   string `json:"LineNo"`
	LineID   string `json:"LineID"`
	LineName struct {
		ZhTw string `json:"Zh_tw"`
		En   string `json:"En"`
	} `json:"LineName"`
	Geometry        string `json:"Geometry"`
	EncodedPolyline string `json:"EncodedPolyline"`
	UpdateTime      string `json:"UpdateTime"`
}

// Reject invalid WKT before it aborts the whole transaction.
func isValidRailShapeWKT(wkt string) bool {
	t := strings.ToUpper(strings.TrimSpace(wkt))
	if !strings.Contains(t, "(") || !strings.HasSuffix(t, ")") {
		return false
	}
	return strings.HasPrefix(t, "LINESTRING") || strings.HasPrefix(t, "MULTILINESTRING")
}

// LoadShape returns a loader transform for one rail_shapes mode
// ("tra", "thsr", or "metro"). part is "" for the unpartitioned TRA/THSR
// datasets and the metro system code (TRTC/KRTC/...) for metro.
func LoadShape(mode string) func(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, part string) error {
	return func(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, part string) error {
		return loadRailShapePart(ctx, dec, sink, mode, part)
	}
}

func loadRailShapePart(ctx context.Context, dec *json.Decoder, sink pipeline.CopyUpsertSink, mode, part string) error {
	shapes, err := pipeline.DecodeLoadArray[railShapeRow](dec, mode+"_shape", nil)
	if err != nil {
		return err
	}
	system := ""
	if mode == "metro" {
		system = part
	}
	row := [][]any{}
	seen := make(map[string][]any, len(shapes))
	for i, shape := range shapes {
		lineID := strings.TrimSpace(shape.LineID)
		if lineID == "" {
			zap.S().Warnw("skip",
				"component", "load",
				"action", "rail_shape",
				"event", "skip",
				"reason", "empty_line_id",
				"mode", mode,
				"system", system,
				"index", i,
			)
			continue
		}
		if !isValidRailShapeWKT(shape.Geometry) {
			zap.S().Warnw("skip",
				"component", "load",
				"action", "rail_shape",
				"event", "skip",
				"reason", "invalid_geometry",
				"mode", mode,
				"system", system,
				"line_id", lineID,
				"index", i,
			)
			continue
		}
		nameJSON, err := json.Marshal(shape.LineName)
		if err != nil {
			zap.S().Warnw("skip",
				"component", "load",
				"action", "rail_shape",
				"event", "skip",
				"reason", "name_marshal_error",
				"mode", mode,
				"system", system,
				"line_id", lineID,
				"err", err,
			)
			continue
		}
		candidate := []any{mode, system, lineID, string(nameJSON), shape.Geometry, shape.UpdateTime}
		key := mode + "/" + system + "/" + lineID
		if err := pipeline.AppendUniqueLoadRow(&row, seen, key, "line_id", candidate); err != nil {
			zap.S().Warnw("skip",
				"component", "load",
				"action", "rail_shape",
				"event", "skip",
				"reason", err,
				"mode", mode,
				"system", system,
			)
			continue
		}
	}
	if len(row) == 0 {
		zap.S().Infow("complete",
			"component", "load",
			"action", "rail_shape",
			"event", "complete",
			"mode", mode,
			"system", system,
			"reason", "no_data",
		)
		return nil
	}
	return sink.CopyUpsert(ctx, pipeline.CopyUpsertSpec{
		Key: "rail_shape_" + mode,
		PreExec: []pipeline.CopyUpsertStmt{
			{SQL: "DELETE FROM rail_shapes WHERE mode=$1 AND system=$2", Args: []any{mode, system}},
		},
		CreateSQL: `CREATE TEMP TABLE temp_rail_shape (
				mode text,
				system text,
				line_id text,
				line_name text,
				geom text,
				updated_at text
			) ON COMMIT DROP`,
		TempTable: "temp_rail_shape",
		CopyCols:  []string{"mode", "system", "line_id", "line_name", "geom", "updated_at"},
		InsertSQL: `INSERT INTO rail_shapes (mode, system, line_id, line_name, geom, updated_at)
			SELECT mode, system, line_id, line_name::jsonb, ST_GeomFromText(geom, 4326),
				NULLIF(updated_at, '')::timestamptz
			FROM temp_rail_shape
			ON CONFLICT (mode, system, line_id) DO UPDATE SET
				line_name = EXCLUDED.line_name,
				geom = EXCLUDED.geom,
				updated_at = EXCLUDED.updated_at`,
	}, row)
}
