package shared

import (
	"context"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/go-resty/resty/v2"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

// Field kinds of the daily TDX usage hash. A field is "{kind}:{name}", where
// name is the fetch name passed to Get/GetInto, or TDXUsageTotal for the
// running day totals.
const (
	TDXUsageCalls       = "calls"
	TDXUsageNotModified = "not_modified"
	TDXUsageBytes       = "bytes"
	TDXUsageTotal       = "_total"
)

const (
	_tdxUsageTTL          = 8 * 24 * time.Hour
	_tdxUsageWriteTimeout = 2 * time.Second
)

// Taiwan has kept UTC+8 without daylight saving since 1979, so a fixed zone
// names the same day as Asia/Taipei without depending on tzdata.
var _tdxUsageZone = time.FixedZone("Asia/Taipei", 8*60*60)

// TDXUsageKey is the usage hash of one Taipei day (YYYY-MM-DD).
func TDXUsageKey(day string) string { return "shared:tdx:usage:" + day }

// TDXUsageField is the hash field holding one kind of count for one name.
func TDXUsageField(kind, name string) string { return kind + ":" + name }

// TDXUsageDay is the Taipei day t falls on, the unit TDX bills by.
func TDXUsageDay(t time.Time) string { return t.In(_tdxUsageZone).Format(time.DateOnly) }

type tdxUsageNameKey struct{}

func withTDXUsageName(ctx context.Context, name string) context.Context {
	return context.WithValue(ctx, tdxUsageNameKey{}, name)
}

type tdxUsage struct {
	name        string
	notModified int64
	bytes       int64
}

// installTDXUsage counts the requests of the client's Get/GetInto. Clients
// from NewAuthedClient (the api booking proxy, the pipeline's Taoyuan
// turnaround landing) are separate resty clients and are not counted.
func installTDXUsage(client *resty.Client, store TDXStore) {
	redisStore, ok := store.(RedisTDXStore)
	if !ok {
		return
	}
	recorder := tdxUsageRecorder{rc: redisStore.RC, now: time.Now}
	client.SetTransport(tdxUsageTransport{base: client.GetClient().Transport, record: recorder.record})
}

// tdxUsageTransport sees every attempt, retries included, because TDX bills
// each one. The client sets Accept-Encoding itself, so net/http leaves the
// body compressed and the bytes read here are the bytes TDX bills.
type tdxUsageTransport struct {
	base   http.RoundTripper
	record func(tdxUsage)
}

func (t tdxUsageTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	name, _ := req.Context().Value(tdxUsageNameKey{}).(string)
	resp, err := t.base.RoundTrip(req)
	if err != nil {
		// A request that got no response still counts as a call: TDX may have
		// served it before the connection failed.
		t.record(tdxUsage{name: name})
		return resp, err
	}
	usage := tdxUsage{name: name, notModified: tdxNotModifiedCount(resp.StatusCode)}
	resp.Body = &tdxCountingBody{ReadCloser: resp.Body, usage: usage, record: t.record}
	return resp, nil
}

func tdxNotModifiedCount(status int) int64 {
	if status == http.StatusNotModified {
		return 1
	}
	return 0
}

// tdxCountingBody records on Close, so bodies drained on retry, on a 304 or
// after decoding all count; a body closed early counts only what was read.
type tdxCountingBody struct {
	io.ReadCloser

	usage  tdxUsage
	record func(tdxUsage)
	once   sync.Once
}

func (b *tdxCountingBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	b.usage.bytes += int64(n)
	return n, err
}

func (b *tdxCountingBody) Close() error {
	b.once.Do(func() { b.record(b.usage) })
	return b.ReadCloser.Close()
}

type tdxUsageRecorder struct {
	rc  redis.Cmdable
	now func() time.Time
}

// record never fails the fetch: a Redis error loses one count. It runs on its
// own context so a fetch whose tick was cancelled is still counted.
func (r tdxUsageRecorder) record(usage tdxUsage) {
	ctx, cancel := context.WithTimeout(context.Background(), _tdxUsageWriteTimeout)
	defer cancel()
	key := TDXUsageKey(TDXUsageDay(r.now()))
	_, err := r.rc.Pipelined(ctx, func(pipe redis.Pipeliner) error {
		for _, name := range []string{usage.name, TDXUsageTotal} {
			pipe.HIncrBy(ctx, key, TDXUsageField(TDXUsageCalls, name), 1)
			pipe.HIncrBy(ctx, key, TDXUsageField(TDXUsageNotModified, name), usage.notModified)
			pipe.HIncrBy(ctx, key, TDXUsageField(TDXUsageBytes, name), usage.bytes)
		}
		pipe.Expire(ctx, key, _tdxUsageTTL)
		return nil
	})
	if err != nil {
		zap.S().Warnw("record failed", "component", "tdx", "action", "usage", "event", "record_failed", "name", usage.name, "err", err)
	}
}
