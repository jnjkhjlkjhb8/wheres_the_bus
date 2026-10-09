package raw

import (
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"time"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/history"
	"go.uber.org/zap"
)

var _rawArchiveCols = []string{"dataset", "partition_val", "last_modified", "landing_cycle", "fetched_at", "payload"}

func ArchivePayload(
	ctx context.Context,
	db history.Execer,
	t Target,
	marker, landingCycle string,
	body io.ReadSeeker,
) {
	if db == nil || body == nil {
		return
	}
	payload, err := gzipAll(body)
	if err != nil {
		zap.S().Errorw("compress error", "component", "raw_archive", "table", t.Table, "partition", t.PartVal, "err", err)
		return
	}
	row := []any{t.Table, t.PartVal, marker, landingCycle, time.Now(), payload}
	if err := history.Insert(ctx, db, "raw_tdx_archive", _rawArchiveCols, [][]any{row}); err != nil {
		zap.S().Errorw("insert error", "component", "raw_archive", "table", t.Table, "partition", t.PartVal, "err", err)
		return
	}
	zap.S().Infow("archived payload",
		"component", "raw_archive",
		"table", t.Table,
		"partition", t.PartVal,
		"marker", marker,
		"bytes", len(payload),
	)
}

func gzipAll(r io.ReadSeeker) ([]byte, error) {
	if _, err := r.Seek(0, io.SeekStart); err != nil {
		return nil, _oops.Wrapf(err, "rewind payload")
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := io.Copy(zw, r); err != nil {
		return nil, _oops.Wrapf(err, "compress payload")
	}
	if err := zw.Close(); err != nil {
		return nil, _oops.Wrapf(err, "finish gzip stream")
	}
	if _, err := r.Seek(0, io.SeekStart); err != nil {
		return nil, _oops.Wrapf(err, "rewind payload after compress")
	}
	return buf.Bytes(), nil
}
