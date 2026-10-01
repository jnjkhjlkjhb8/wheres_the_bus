package bus

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/busmodel"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/worker/internal/predict"
)

func TestMergeBusFares(t *testing.T) {
	dir0 := &models.Bus_Fare{
		FarePricingType: 1, IsFreeBus: false,
		StageFaresJson: []byte(`[{"Direction":0,"OriginStage":{"StopID":"S1"},"DestinationStage":{"StopID":"S2"},"Fares":[{"FareClass":1,"TicketType":1,"Price":30}]}]`),
	}
	dir1 := &models.Bus_Fare{
		FarePricingType: 2, IsFreeBus: false,
		StageFaresJson: []byte(`[{"Direction":1,"OriginStage":{"StopID":"S2"},"DestinationStage":{"StopID":"S1"},"Fares":[{"FareClass":1,"TicketType":1,"Price":30}]}]`),
	}

	merged := mergeBusFares([]*models.Bus_Fare{dir0, dir1})
	if merged.GetFarePricingType() != 1 {
		t.Fatalf("FarePricingType = %d, want the first candidate's (1)", merged.GetFarePricingType())
	}
	var entries []map[string]any
	if err := json.Unmarshal(merged.GetStageFaresJson(), &entries); err != nil {
		t.Fatalf("decode merged StageFaresJson: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("merged StageFares entries = %d, want 2 (one per direction, FDPL-67)", len(entries))
	}

	// Identical entries across candidates (e.g. the same route-wide offer seen
	// through two native SubRouteIDs) must not be duplicated in the merge.
	dup := mergeBusFares([]*models.Bus_Fare{dir0, dir0})
	if err := json.Unmarshal(dup.GetStageFaresJson(), &entries); err != nil {
		t.Fatalf("decode deduped StageFaresJson: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("deduped StageFares entries = %d, want 1", len(entries))
	}
}

type recordingBusTx struct {
	execs               []string
	copies              []string
	failSQL             string
	failCopy            string
	queryErr            error
	unsafeGroupRekey    bool
	commitErr           error
	committed           bool
	rolledBack          bool
	rollbackContextLive bool
}

func (tx *recordingBusTx) Exec(_ context.Context, sql string, _ ...any) (pgconn.CommandTag, error) {
	tx.execs = append(tx.execs, sql)
	if tx.failSQL != "" && strings.Contains(sql, tx.failSQL) {
		return pgconn.CommandTag{}, errors.New("injected exec failure")
	}
	return pgconn.NewCommandTag("OK"), nil
}

func (tx *recordingBusTx) CopyFrom(_ context.Context, table pgx.Identifier, _ []string, _ pgx.CopyFromSource) (int64, error) {
	name := table.Sanitize()
	tx.copies = append(tx.copies, name)
	if tx.failCopy != "" && strings.Contains(name, tx.failCopy) {
		return 0, errors.New("injected copy failure")
	}
	return 1, nil
}

func (tx *recordingBusTx) QueryRow(_ context.Context, _ string, _ ...any) pgx.Row {
	return boolRow{value: tx.unsafeGroupRekey, err: tx.queryErr}
}

func (tx *recordingBusTx) Commit(_ context.Context) error {
	if tx.commitErr != nil {
		return tx.commitErr
	}
	tx.committed = true
	return nil
}

func (tx *recordingBusTx) Rollback(ctx context.Context) error {
	tx.rolledBack = true
	tx.rollbackContextLive = ctx.Err() == nil
	return nil
}

type boolRow struct {
	value bool
	err   error
}

func (r boolRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	if len(dest) != 1 {
		return fmt.Errorf("destinations = %d, want 1", len(dest))
	}
	value, ok := dest[0].(*bool)
	if !ok {
		return fmt.Errorf("destination is %T, want *bool", dest[0])
	}
	*value = r.value
	return nil
}

type recordingBusBeginner struct {
	tx       *recordingBusTx
	beginErr error
	begins   int
}

func (b *recordingBusBeginner) BeginBusTx(context.Context) (busTx, error) {
	b.begins++
	if b.beginErr != nil {
		return nil, b.beginErr
	}
	return b.tx, nil
}

func mustValidBusSnapshot(t *testing.T) *busCitySnapshot {
	t.Helper()
	snapshot, err := readBusCitySnapshot(context.Background(), validBusSnapshotSource("Taipei"), "Taipei")
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	return snapshot
}

func TestWriteBusCitySnapshotRollsBackStationMapAndUsesLiveRollbackContext(t *testing.T) {
	tx := &recordingBusTx{failSQL: "INSERT INTO bus_station_stop_map"}
	beginner := &recordingBusBeginner{tx: tx}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := writeBusCitySnapshot(ctx, beginner, mustValidBusSnapshot(t))
	if err == nil {
		t.Fatal("injected stop-map failure returned nil")
	}
	if tx.committed {
		t.Fatal("transaction committed after stop-map failure")
	}
	if !tx.rolledBack || !tx.rollbackContextLive {
		t.Fatalf("rollback = %v, live context = %v", tx.rolledBack, tx.rollbackContextLive)
	}
}

func TestWriteBusCitySnapshotClearsEmptyScheduleAndPrunesInDependencyOrder(t *testing.T) {
	tx := &recordingBusTx{}
	if err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t)); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}
	joined := strings.Join(tx.execs, "\n")
	for _, required := range []string{
		"DELETE FROM bus_schedule", "DELETE FROM bus_stations", "DELETE FROM bus_station_group_members", "DELETE FROM bus_station_groups",
	} {
		if !strings.Contains(joined, required) {
			t.Fatalf("writer did not execute %q", required)
		}
	}
	memberPrune := indexSQL(tx.execs, "DELETE FROM bus_station_group_members")
	emptyGroupPrune := indexSQL(tx.execs, "NOT EXISTS (SELECT 1 FROM bus_station_group_members")
	if memberPrune < 0 || emptyGroupPrune < 0 || memberPrune >= emptyGroupPrune {
		t.Fatalf("member prune index=%d, empty-group prune index=%d, want member first", memberPrune, emptyGroupPrune)
	}
	if !tx.committed {
		t.Fatal("valid snapshot did not commit")
	}
}

func TestBusSubrouteUpsertRefreshesMutableFieldsAndUsesStationID(t *testing.T) {
	for _, field := range []string{"route_uid = EXCLUDED.route_uid", "route_name = EXCLUDED.route_name", "sub_route_name = EXCLUDED.sub_route_name", "s ->> 'StationID'"} {
		if !strings.Contains(_busSubroutesUpsertSQL, field) {
			t.Fatalf("busSubroutesUpsertSQL missing %q", field)
		}
	}
	if strings.Contains(_busSubroutesUpsertSQL, "s ->> 'StationUID'") {
		t.Fatal("busSubroutesUpsertSQL still extracts nonexistent StationUID")
	}
}

func TestWriteBusCitySnapshotReturnsBeginAndCommitFailures(t *testing.T) {
	beginErr := errors.New("begin failed")
	if err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{beginErr: beginErr}, mustValidBusSnapshot(t)); !errors.Is(err, beginErr) {
		t.Fatalf("begin error = %v, want %v", err, beginErr)
	}
	commitErr := errors.New("commit failed")
	tx := &recordingBusTx{commitErr: commitErr}
	if err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t)); !errors.Is(err, commitErr) {
		t.Fatalf("commit error = %v, want %v", err, commitErr)
	}
	if !tx.rolledBack || !tx.rollbackContextLive {
		t.Fatal("commit failure did not receive bounded background rollback")
	}
	queryErr := errors.New("rekey query failed")
	tx = &recordingBusTx{queryErr: queryErr}
	if err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t)); !errors.Is(err, queryErr) {
		t.Fatalf("rekey query error = %v, want %v", err, queryErr)
	}
}

func TestWriteBusCitySnapshotReturnsEveryStageFailure(t *testing.T) {
	for _, temp := range []string{
		"temp_bus", "temp_bus_operators", "temp_bus_stations", "temp_bus_groups", "temp_bus_members",
		"temp_bus_schedule", "temp_bus_static", "temp_bus_stop_map", "temp_bus_stop_alias",
	} {
		t.Run("create "+temp, func(t *testing.T) {
			tx := &recordingBusTx{failSQL: "CREATE TEMP TABLE " + temp + " "}
			if err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t)); err == nil {
				t.Fatalf("create %s failure returned nil", temp)
			}
		})
		t.Run("copy "+temp, func(t *testing.T) {
			tx := &recordingBusTx{failCopy: temp}
			if err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t)); err == nil {
				t.Fatalf("copy %s failure returned nil", temp)
			}
		})
	}
	for _, fragment := range []string{
		"SET LOCAL lock_timeout",
		"INSERT INTO bus_subroutes", "INSERT INTO bus_operators", "INSERT INTO bus_stations", "INSERT INTO bus_station_groups",
		"INSERT INTO bus_station_group_members", "DELETE FROM bus_schedule", "INSERT INTO bus_schedule",
		"INSERT INTO bus_static", "DELETE FROM bus_station_stop_map", "INSERT INTO bus_station_stop_map",
		"DELETE FROM bus_stop_alias", "INSERT INTO bus_stop_alias",
		"DELETE FROM bus_station_group_members", "DELETE FROM bus_station_groups current",
		"DELETE FROM bus_stations", "DELETE FROM bus_subroutes", "DELETE FROM bus_static", "DELETE FROM bus_operators",
	} {
		t.Run(fragment, func(t *testing.T) {
			tx := &recordingBusTx{failSQL: fragment}
			if err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t)); err == nil {
				t.Fatalf("%s failure returned nil", fragment)
			}
			if tx.committed {
				t.Fatalf("%s failure committed", fragment)
			}
		})
	}
}

func TestWriteBusCitySnapshotRollsBackOperatorsWithLaterFailure(t *testing.T) {
	tx := &recordingBusTx{failSQL: "INSERT INTO bus_static"}
	err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t))
	if err == nil {
		t.Fatal("later static failure returned nil")
	}
	if indexSQL(tx.execs, "INSERT INTO bus_operators") < 0 {
		t.Fatal("writer did not stage operator target write before later failure")
	}
	if tx.committed || !tx.rolledBack {
		t.Fatalf("committed/rolledBack = %v/%v, want false/true", tx.committed, tx.rolledBack)
	}
}

func TestWriteBusCitySnapshotUsesStableInterCityGroupTieBreak(t *testing.T) {
	tx := &recordingBusTx{}
	if err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t)); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}
	var memberUpsert string
	for _, statement := range tx.execs {
		if strings.Contains(statement, "INSERT INTO bus_station_group_members") {
			memberUpsert = statement
			break
		}
	}
	orderStart := strings.Index(memberUpsert, "ORDER BY")
	limitStart := strings.Index(memberUpsert, "LIMIT 1")
	if orderStart < 0 || limitStart < orderStart || !strings.Contains(memberUpsert[orderStart:limitStart], "g.group_uid") {
		t.Fatalf("member upsert lacks stable group_uid tie-break: %s", memberUpsert)
	}
}

func TestWriteBusCitySnapshotRejectsUnsafeGroupRekeyBeforeTargetWrite(t *testing.T) {
	tx := &recordingBusTx{unsafeGroupRekey: true}
	err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t))
	if !errors.Is(err, errBusSnapshotConflict) {
		t.Fatalf("rekey error = %v, want errBusSnapshotConflict", err)
	}
	for _, statement := range tx.execs {
		if strings.Contains(statement, "INSERT INTO bus_") {
			t.Fatalf("unsafe rekey performed target write: %s", statement)
		}
	}
}

func TestWriteBusCitySnapshotNeverReadsRawTDXFromTarget(t *testing.T) {
	tx := &recordingBusTx{}
	if err := writeBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, mustValidBusSnapshot(t)); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}
	for _, statement := range tx.execs {
		if strings.Contains(strings.ToLower(statement), "raw_tdx") {
			t.Fatalf("target transaction accessed raw database: %s", statement)
		}
	}
}

func TestInvalidateBusStaticAfterCommitReturnsRedisFailureAndDropsOnlyCity(t *testing.T) {
	predict.StoreStaticMapIn(predict.StaticMapCache(), "TPE", []busmodel.StationMap{{StopUID: "old-tpe"}}, "1", time.Now())
	predict.StoreStaticMapIn(predict.StaticMapCache(), "NWT", []busmodel.StationMap{{StopUID: "old-nwt"}}, "1", time.Now())
	t.Cleanup(predict.InvalidateStaticMap)
	if err := invalidateBusStaticAfterCommit(context.Background(), nil, "Taipei"); err == nil {
		t.Fatal("nil Redis returned nil post-commit invalidation error")
	}
	if _, ok := predict.StaticMapCache().Load("TPE"); ok {
		t.Fatal("Taipei local cache was not invalidated")
	}
	if _, ok := predict.StaticMapCache().Load("NWT"); !ok {
		t.Fatal("Taipei invalidation cleared unrelated NewTaipei cache")
	}
}

func TestPersistBusCitySnapshotInvalidatesOnlyAfterCommit(t *testing.T) {
	snapshot := mustValidBusSnapshot(t)
	tx := &recordingBusTx{}
	cacheErr := errors.New("redis unavailable")
	invalidated := false
	err := persistBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, snapshot, func() error {
		invalidated = true
		if !tx.committed {
			t.Fatal("cache invalidation ran before transaction commit")
		}
		return cacheErr
	})
	if !errors.Is(err, errBusPostCommitCache) || !errors.Is(err, cacheErr) {
		t.Fatalf("post-commit error = %v, want cache sentinel and cause", err)
	}
	if !invalidated {
		t.Fatal("successful commit did not invoke cache invalidation")
	}

	tx = &recordingBusTx{failSQL: "INSERT INTO bus_station_stop_map"}
	invalidated = false
	if err := persistBusCitySnapshot(context.Background(), &recordingBusBeginner{tx: tx}, snapshot, func() error {
		invalidated = true
		return nil
	}); err == nil {
		t.Fatal("target write failure returned nil")
	}
	if invalidated {
		t.Fatal("failed transaction invoked cache invalidation")
	}
}

func indexSQL(statements []string, fragment string) int {
	for i, statement := range statements {
		if strings.Contains(statement, fragment) {
			return i
		}
	}
	return -1
}
