package raw

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"testing"
)

type readerOnly struct{ io.Reader }

// chunkRecorder captures every chunk passed to insertRawChunks' exec and
// reports each element count as the statement's affected rows.
func chunkRecorder(t *testing.T, chunks *[][]json.RawMessage) func(context.Context, string, ...any) (int64, error) {
	t.Helper()
	return func(_ context.Context, _ string, args ...any) (int64, error) {
		chunk, ok := args[1].([]byte)
		if !ok {
			t.Fatalf("args[1] is not a []byte")
		}
		var elems []json.RawMessage
		if err := json.Unmarshal(chunk, &elems); err != nil {
			return 0, fmt.Errorf("chunk is not a JSON array: %v", err)
		}
		*chunks = append(*chunks, elems)
		return int64(len(elems)), nil
	}
}

func TestInsertRawChunksSplitsLargePayload(t *testing.T) {
	// ~40 elements of ~256KB each ≈ 10MB → must split into 3 chunks of ≤4MB.
	elem := fmt.Sprintf(`{"RouteUID":"TPE1","Pad":"%s"}`, strings.Repeat("x", 256<<10))
	n := 40
	body := "[" + strings.Repeat(elem+",", n-1) + elem + "]"

	var chunks [][]json.RawMessage
	rows, err := insertRawChunks(context.Background(), chunkRecorder(t, &chunks), "bus_route", "{}", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if rows != int64(n) {
		t.Fatalf("rows = %d, want %d", rows, n)
	}
	if len(chunks) < 2 {
		t.Fatalf("payload was not split: %d chunk(s)", len(chunks))
	}
	total := 0
	for i, c := range chunks {
		total += len(c)
		size := 0
		for _, e := range c {
			size += len(e)
		}
		// Chunks flush after crossing rawChunkBytes, so allow one element of overshoot.
		if size > _rawChunkBytes+300<<10 {
			t.Errorf("chunk %d is %d bytes, want ≤ ~%d", i, size, _rawChunkBytes)
		}
	}
	if total != n {
		t.Fatalf("elements across chunks = %d, want %d", total, n)
	}
}

func TestInsertRawChunksEmptyArray(t *testing.T) {
	var chunks [][]json.RawMessage
	rows, err := insertRawChunks(context.Background(), chunkRecorder(t, &chunks), "bus_route", "{}", strings.NewReader("[]"))
	if err != nil {
		t.Fatal(err)
	}
	if rows != 0 || len(chunks) != 1 || len(chunks[0]) != 0 {
		t.Fatalf("empty array: rows=%d chunks=%v, want one empty insert", rows, chunks)
	}
}

func TestInsertRawChunksRejectsNonArray(t *testing.T) {
	if _, err := insertRawChunks(context.Background(), chunkRecorder(t, new([][]json.RawMessage)), "bus_route", "{}", strings.NewReader(`{"a":1}`)); err == nil {
		t.Fatal("non-array payload must error")
	}
}

func TestInsertRawChunksRejectsIncompleteOrTrailingPayload(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{name: "missing closing delimiter", body: `[{"RouteUID":"R1"}`},
		{name: "trailing comma without closing delimiter", body: `[{"RouteUID":"R1"},`},
		{name: "second JSON document", body: `[{"RouteUID":"R1"}] {}`},
		{name: "non-JSON trailing data", body: `[{"RouteUID":"R1"}] nope`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var chunks [][]json.RawMessage
			if _, err := insertRawChunks(context.Background(), chunkRecorder(t, &chunks), "bus_route", "{}", strings.NewReader(tt.body)); err == nil {
				t.Fatalf("insertRawChunks(%q) returned nil error", tt.body)
			}
		})
	}
}

func TestInsertRawChunksAllowsTrailingWhitespace(t *testing.T) {
	var chunks [][]json.RawMessage
	rows, err := insertRawChunks(context.Background(), chunkRecorder(t, &chunks), "bus_route", "{}", strings.NewReader("[] \n\t\r"))
	if err != nil {
		t.Fatal(err)
	}
	if rows != 0 || len(chunks) != 1 {
		t.Fatalf("trailing whitespace: rows=%d chunks=%v, want one empty insert", rows, chunks)
	}
}

func TestInsertRawChunksConsumesReader(t *testing.T) {
	var chunks [][]json.RawMessage
	body := readerOnly{Reader: bytes.NewBufferString(`[{"RouteUID":"R1"}]`)}
	rows, err := insertRawChunks(context.Background(), chunkRecorder(t, &chunks), "bus_route", "{}", body)
	if err != nil {
		t.Fatal(err)
	}
	if rows != 1 || len(chunks) != 1 || len(chunks[0]) != 1 {
		t.Fatalf("rows=%d chunks=%v, want one streamed row", rows, chunks)
	}
}
