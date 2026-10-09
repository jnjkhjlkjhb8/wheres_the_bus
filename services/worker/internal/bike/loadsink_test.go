package bike

import (
	"bytes"
	"encoding/json"
)

// copyUpsertCall records one captured CopyUpsert invocation so a test can
// assert on the spec and rows a transform produced.

// fakeLoadSink is the write seam's in-memory adapter. The bike loaders write
// only through CopyUpsert, so that is all this needs to satisfy — the loader
// tests keep their own wider copy.

func decodeInto(body string) *json.Decoder {
	return json.NewDecoder(bytes.NewReader([]byte(body)))
}
