package static

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestStaticVersionDatabaseMarkerUsesLatestLoadDay(t *testing.T) {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("DATABASE_URL not set")
	}
	admin, err := pgxpool.New(t.Context(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	schema := fmt.Sprintf("quality_static_version_%d", os.Getpid())
	if _, err := admin.Exec(t.Context(), "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = admin.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE") }()
	if _, err := admin.Exec(t.Context(), "CREATE TABLE "+schema+".pipeline_runs (LIKE public.pipeline_runs INCLUDING ALL)"); err != nil {
		t.Fatal(err)
	}
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	db, err := pgxpool.NewWithConfig(t.Context(), config)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	request := func(want string) {
		t.Helper()
		gin.SetMode(gin.TestMode)
		router := gin.New()
		router.GET(StaticVersionPath, HandleStaticVersion(db))
		recorder := getStaticVersion(t, router)
		var response staticVersionResponse
		if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if recorder.Code != 200 || response.Version != want {
			t.Fatalf("static version status=%d body=%s, want %s", recorder.Code, recorder.Body, want)
		}
	}
	request("0")
	if _, err := db.Exec(t.Context(), `INSERT INTO pipeline_runs(job,run_date,completed_at) VALUES('load','2026-10-10',to_timestamp(200)),('load','2026-10-11',to_timestamp(100)),('other','2026-10-12',to_timestamp(300))`); err != nil {
		t.Fatal(err)
	}
	request("100")
	db.Close()
	router := gin.New()
	router.GET(StaticVersionPath, HandleStaticVersion(db))
	if recorder := getStaticVersion(t, router); recorder.Code != 503 {
		t.Fatalf("closed DB status = %d", recorder.Code)
	}
}
