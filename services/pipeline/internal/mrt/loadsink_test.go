package mrt

import (
	"bytes"
	"context"
	"encoding/json"

	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared/pipeline"
)

// copyUpsertCall records one captured CopyUpsert invocation so a test can
// assert on the spec and rows a transform produced.
type copyUpsertCall struct {
	spec pipeline.CopyUpsertSpec
	rows [][]any
}

// fakeLoadSink is the write seam's in-memory adapter. The bike loaders write
// only through CopyUpsert, so that is all this needs to satisfy — the loader
// tests keep their own wider copy.
type fakeLoadSink struct {
	calls []copyUpsertCall
}

func (f *fakeLoadSink) CopyUpsert(_ context.Context, spec pipeline.CopyUpsertSpec, rows [][]any) error {
	f.calls = append(f.calls, copyUpsertCall{spec: spec, rows: rows})
	return nil
}

func decodeInto(body string) *json.Decoder {
	return json.NewDecoder(bytes.NewReader([]byte(body)))
}
