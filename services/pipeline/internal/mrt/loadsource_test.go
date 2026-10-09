package mrt

import (
	"context"
	"time"
)

// Load-source fake. The loader tests keep their own copy.

// fakeLoadSource serves fixed JSON per (table,partVal) and a fixed fetched_at.
// It is the pipeline.LoadSource seam's in-memory adapter for unit tests.
type fakeLoadSource struct {
	json    map[string][]byte // Key: table + "|" + partVal
	errs    map[string]error
	fetched time.Time
	calls   []string
}

func (f *fakeLoadSource) DatasetJSON(_ context.Context, table, _, partVal string) ([]byte, time.Time, error) {
	f.calls = append(f.calls, table+"|"+partVal)
	if err := f.errs[table+"|"+partVal]; err != nil {
		return nil, time.Time{}, err
	}
	b, ok := f.json[table+"|"+partVal]
	if !ok {
		return []byte("[]"), f.fetched, nil
	}
	return b, f.fetched, nil
}
