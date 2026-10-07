# 設定與環境變數

## 每服務 env allowlist

`docker/docker-compose.yaml` 過去讓 router、functions、ingestor、loader、
powersync 全部載入同一個 `ENV_FILE`；任一容器失陷即可讀到全部憑證（DB、
TDX、MQTT、PowerSync、Sentry、Firebase）。現在每個 service 只載入自己的
allowlisted env 檔：

- operator 端契約不變：仍然只填一份 `env/<env>.env`（`env/test.env.example`
  等為範本）。
- `scripts/render-env.sh <source-env-file> <output-dir>` 依
  `scripts/env-allowlists/<service>.txt`（router / functions / ingestor /
  loader / powersync）從來源檔篩出每個 service 實際會用到的變數，寫成
  `<output-dir>/<service>.env`。
- `docker/docker-compose.yaml` 每個 service 的 `env_file:` 改成
  `${ENV_FILE_<SERVICE>:-${ENV_FILE:-./.env}}`；`make up-test` /
  `up-staging` / `up-prod` 會先跑 `render-env-%` 把
  `env/.rendered/<env>/*.env` 產生出來並指到對應變數。未設定
  `ENV_FILE_<SERVICE>` 時退回單一 `ENV_FILE`（`check-container-hardening.sh`
  只設 `ENV_FILE`，行為不變）。

**為何選 render-env.sh 而非把 `env/<env>.env` 直接拆成五份**：兩者達到的
安全性質相同（每個容器永遠只看得到自己 allowlist 內的變數），但
render 方案對 operator 的遷移成本是零——仍然只填一份熟悉的檔案，allowlist
執行完全在幕後發生；拆檔方案則要求 operator 同時維護五份檔案、記住哪個
變數該填在哪份，對單機小團隊部署而言是不必要的心智負擔換來相同的效果，
diff 也更大（改動集中在 `docker-compose.yaml`、`Makefile`、新增兩個
`scripts/` 檔案，而不用動任何既有的 `env/*.env.example`／`env/*.env` 檔案
結構）。

**各 service 的 allowlist（來源：grep `os.Getenv` / `shared.EnvInt32`，見
`scripts/env-allowlists/*.txt` 檔頭註解）：**

| Service | 讀取的變數                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
|---|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| router | `DATABASE_URL`, `PG_SCHEMA`, `ROUTER_DB_MAX_CONNS`, `ROUTER_DB_MIN_CONNS`, `ROUTER_METRICS_TOKEN`, `ROUTER_TRUSTED_PROXIES`, `ROUTER_MAX_LIVE_STREAMS`, `ROUTER_LIVE_SUBSCRIBER_QUEUE`, `REDIS_PASSWORD`, `TDX_CLIENT_ID`/`TDX_CLIENT_SECRET`（MaaS 路線規劃的專屬 carve-out，見下方說明）, `TRTC_USERNAME`/`TRTC_PASSWORD`（捷運下車提醒 `CreateTrack` 建立 session 時用 GetTrainInfo 驗證車廂綁定；空值 = no-op，回 NotFound；ADR-0015）, `FIREBASE_ENABLED`, `FIREBASE_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS`, `APP_ENV`, `GRPC_TLS`, `GRPC_TLS_CERT_FILE`, `GRPC_TLS_KEY_FILE`, `SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_TRACES_SAMPLE_RATE`, `FEEDBACK_WEBHOOK_URL`（回報通知的 chat webhook；空值 = 不通知，回報仍照常寫入 `feedback_thread`）, `GTFS_RT_CREDENTIAL`（GTFS-RT endpoint 的共享密鑰；空值 = 該路由完全不掛載，ADR-0019）, `MAAS_BACKEND`（`motis`（預設）或 `tdx`——路線規劃由誰返回。手動 kill switch, `MOTIS_BASE_URL`（router 連到 MOTIS 的位址；prod 是 `http://motis:8080`，staging 走 host gateway 連 prod 發布的埠）, `POST /api/track/cancel`（無新增環境變數；掛載條件是 Redis 存在。取消一個追蹤 session，只吃 track_id——那是伺服器產生、只送到擁有它那台裝置的 UUIDv4，本身即憑證。給 Android 卡片上「取消追蹤」在 App process 已死時使用；FDPL-65） |
| functions（`ROLE=""`，即 legacy prod 路徑：即時 ETA cron、通知、MQTT） | `DATABASE_URL`, `PG_SCHEMA`, `FUNCTIONS_DB_MAX_CONNS`/`MIN_CONNS`, `RAW_DATABASE_URL`, `RAW_DB_MAX_CONNS`, `LOAD_QUARANTINE_MAX_RATIO`, `REDIS_PASSWORD`, `CWA_API_KEY`, `MQTT_CLIENT_ID`/`USERNAME`/`PASSWORD`, `TDX_CLIENT_ID`/`TDX_CLIENT_SECRET`（`registerLiveCrons` 直接打 TDX 即時端點）, `TRTC_USERNAME`/`TRTC_PASSWORD`（北捷官網 SOAP API,trtcEta 即時到站+擁擠度,空值 = 跳過;ADR-0014）, `APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_TOPIC`/`APNS_P8`/`APNS_SANDBOX`（捷運追蹤卡的 iOS 推播刷新；四者任一為空 = iOS 推播關閉，Android 走 FCM 不受影響；金鑰格式錯誤則拒絕啟動；ADR-0018）, `FIREBASE_ENABLED`, `FIREBASE_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS`, `APP_ENV`, `BUS_ETA_MODEL_PATH`, `HEALTH_FILE`, `SENTRY_*`, `ARCHIVE_MYSQL_DSN`（MySQL 歷史／封存主機，見 `migrations/mysql/` 與 `docs/archive.md`；`bus_eta_history`、`bus_stop_event`、`bike_availability_history` 只存在那裡，PostgreSQL 上的同名表都已 DROP，另有 `raw_tdx_archive` 與 `live_archive`／`live_archive_bus` 兩張即時原文表。空值 = 完全不收集歷史、也完全不封存；設了但連不上則拒絕啟動，不會靜默不記錄。必須帶 `parseTime=true`。**僅 prod 設定**：staging 指向同一台會把它的觀測混進 prod 的 ETA 訓練資料，即時原文也會多出一份時間戳只差幾秒、事後無從分辨的副本）                                                                                                                                                                         |
| ingestor（`ROLE=ingestor`） | `DATABASE_URL`, `PG_SCHEMA`, `INGEST_DB_MAX_CONNS`/`MIN_CONNS`, `TDX_CLIENT_ID`/`TDX_CLIENT_SECRET`, `INGEST_ON_BOOT`, `REDIS_PASSWORD`, `HEALTH_FILE`, `SENTRY_*`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| loader（`ROLE=loader`） | `DATABASE_URL`, `PG_SCHEMA`, `LOAD_DB_MAX_CONNS`/`MIN_CONNS`, `RAW_DATABASE_URL`, `RAW_DB_MAX_CONNS`, `LOAD_ON_BOOT`, `LOAD_QUARANTINE_MAX_RATIO`, `PG_STATEMENT_TIMEOUT`, `REDIS_PASSWORD`, `HEALTH_FILE`, `SENTRY_*`, `GTFS_OUT_DIR`（GTFS 靜態 feed 的輸出目錄；空值 = `/data/gtfs`，即 compose 掛在 loader 上的 `gtfs_feed` named volume。loader 的 root filesystem 是 `read_only: true`，寫到 volume 以外的任何路徑都會失敗）（沒有 TDX——loader 只讀已落地的 `raw_tdx`，從不呼叫 TDX）                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| powersync | `PS_DATABASE_URL`, `PS_SOURCE_DATABASE_URL`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |

**與 `AGENTS.md` 摘要表的差異**：`AGENTS.md` 的 `TDX_CLIENT_ID` /
`TDX_CLIENT_SECRET` 說明只涵蓋 ingestor 的每日落地工作。實際 grep 程式碼
發現 router（`services/api/main.go`／`maas.go` 的 MaaS 路線規劃）與
functions 的 legacy prod 路徑（`registerLiveCrons` 即時 ETA cron）也直接
建立已驗證的 TDX client 並發出請求——這是既有行為，不是本次變更引入的；
本次只是把它精確地寫進 allowlist，而不是照抄摘要表的假設。

## Redis
- `REDIS_ADDR`
  - 格式：`host:port`
- `REDIS_PASSWORD`（O7 / review_results.md P2-03）
  - `docker/docker-compose.yaml` 的 redis service 帶 `--requirepass
    "${REDIS_PASSWORD:-}"`；留空等同不設密碼（`redis-server` 對空字串的
    `--requirepass` 視為停用驗證），這是 test env 的預設值，讓本機 Redis
    保持免驗證。staging / prod 必須填入真正的密碼。
  - `services/shared/bootstrap.go` 的 `ConnectRedis` 讀取這個變數並傳給
    `redis.Options.Password`；未設定時行為與變更前完全相同（無 AUTH）。

## PostgreSQL
- `DATABASE_URL`
  - 連線字串

## TDX
- `TDX_CLIENT_ID`
- `TDX_CLIENT_SECRET`
  - ingestor 容器（`ROLE=ingestor`）每個環境都會啟動（只有 `make up-test` 不啟動），但 TDX 憑證只放在 prod；缺任一憑證時 `ingestRaw` 直接跳過整趟落地、不發出任何請求（真正的 no-op）。
  - staging / test 留空即可（ADR-0005 Consequences）：loader 從 `raw_tdx` 載入，不呼叫 TDX。
  - ⚠️ staging 與 prod 共用同一個資料庫，切勿在 staging 設定 TDX 憑證：兩個 ingestor 會在共用的 `raw_tdx` 上競爭彼此的分割 `DELETE`/`INSERT`。若 staging 必須落地，請改用獨立資料庫。

## 資料載入（loader）
- `LOAD_ON_BOOT`
  - functions 容器啟動時立即執行一次 03:30 load（回填該環境 schema）。
  - 預設關閉；設為 `"true"` 啟用。對應 ingestor 的 `INGEST_ON_BOOT`。
- `INGEST_ON_BOOT`
  - `ROLE=ingestor` 啟動時立即執行一次 03:00 raw landing。
  - 預設關閉；設為 `"true"` 啟用。
- `RAW_DATABASE_URL`（選用）
  - loader 讀取共用 `raw_tdx` 的 DSN；未設定時退回 `DATABASE_URL`。
  - 用於 test / staging 讀共用`raw_tdx`（唯讀），同時 sink 到自己的本地 schema。

## TDX MQTT
- `MQTT_CLIENT_ID`
  - 由 TDX 會員中心 → 資料服務 → 存取金鑰取得
  - 若留空則略過 MQTT 訂閱
- `MQTT_USERNAME`
- `MQTT_PASSWORD`

## HTTP / PowerSync
- `POWERSYNC_URL`
  - Flutter build-time dart-define: `--dart-define=POWERSYNC_URL=http://your-debian-server:8080`
  - PowerSync service endpoint (Debian server)
- `API_BASE_URL`
  - Flutter build-time dart-define: `--dart-define=API_BASE_URL=http://your-go-server:8080`
  - Go backend HTTP server (JWT + embed endpoints)
  - Default: `http://localhost:8080`

## PowerSync server (powersync/.env)
- `DATABASE_URL`
  - PostgreSQL connection string (same as Go backend)
- `POWERSYNC_JWKS_URL`
  - Full URL of Go backend JWKS endpoint, reachable from Debian server
  - e.g. `http://go-server-host:8080/api/.well-known/jwks.json`

## Bus ETA Prediction

- `CWA_API_KEY`
  - CWA Open Data API 金鑰，申請網址：opendata.cwa.gov.tw
  - 若留空則略過天氣同步（weatherSync 不執行）
- `BUS_ETA_MODEL_PATH`
  - XGBoost 模型檔案路徑
  - 預設：`./model/bus_eta.json`
- 若檔案不存在則僅用班表 + travel avg（無 ML 修正）

## PowerSync sync token（O7 / review_results.md P2-03）

`GET /api/token/powersync`（`services/api/http.go` `handleToken`）issues
一個 RS256 JWT，供 PowerSync client 同步用：

- **TTL**：1 小時（原本 24 小時）。`app/lib/core/powersync/powersync_service.dart`
  的 `PowerSyncCredentialFetch` 在到期前就會重新 fetch，所以縮短 TTL 不影響
  正常使用；縮短的目的純粹是縮小 token 外洩後的可用視窗。
- **sub 綁定 installation id**：Flutter client 帶 `X-Install-Id` header（與
  gRPC 的 `x-install-id` metadata 同一個值，見
  `app/lib/core/firebase/firebase_call_options.dart` /
  `install_identity.dart`），router 把它塞進 JWT 的 `sub` claim，方便事後
  追查某個外洩 token 屬於哪個安裝。**這不是授權機制**——沒有對應的 secret
  驗證（不同於 gRPC 那對 `x-install-id`/`x-install-secret`），純粹是
  correlation id；未帶 header（或值不合法：空白、超過 128 字元、含控制
  字元）時退回舊行為的 `sub=powersync-client`。
- **刻意不做的事（YAGNI）**：revocation、per-installation quota、rate
  limit 以外的 token 撤銷機制。單機部署的規模不需要這些機制的維運成本；
  真正的防線是短 TTL + `/api/token/powersync` 既有的 rate limit
  （`httpTokenRateLimit`）。

## Router live streams

- ROUTER_MAX_LIVE_STREAMS
  - Router process 可同時維持的 gRPC live stream 上限。
  - 預設：2000。超過上限時回傳 ResourceExhausted，不會再建立 Redis Pub/Sub 訂閱。
  - 單機部署需依照 docs/runbooks/single-host-live-capacity.md 的壓測結果調整，不可直接調高。

- GET /metrics
  - Router Prometheus text metrics endpoint.
  - Exposes active live streams, active upstream channels, replaced slow-client frames, Go goroutine count, plus (O8 / review_results.md P2-04) gRPC request/error counts by method, HTTP request/error counts by route pattern, live-stream disconnect count, Redis error count, and PostgreSQL error count — see `services/obs/metrics.go`.
  - Requires `ROUTER_METRICS_TOKEN` as a `Bearer` credential (`Authorization: Bearer <token>`); `requireMetricsCredential` in `services/api/http.go` rejects the request otherwise. **This is fail-closed by design**: `metricsCredentialFromEnv` refuses to start the router at all if the token is unset or shorter than 32 characters — an empty `env/*.env.example` default (as shipped) will not boot. Generate one before first deploy to any environment and store it in that environment's real `env/<env>.env` (never committed):
    ```
    openssl rand -base64 48
    ```
    Any scraper/dashboard that reads `/metrics` needs the same value in its own credential store.

- GET /api/gtfs-rt/trip-updates.pb
  - The GTFS-RT feed MOTIS polls (ADR-0019). Body is a serialized
    `FeedMessage` (`application/x-protobuf`), rebuilt by `services/worker`
    and handed over through the Redis key `gtfs_rt:feed`; the router only
    returns the bytes.
  - Requires `GTFS_RT_CREDENTIAL` as a `Bearer` credential, minimum 32
    characters. **Unlike `/metrics` this is fail-open-by-omission on purpose**:
    an empty value leaves the route unmounted (404) rather than refusing to
    boot, because an environment with no planner attached should serve no feed.
    A value that is set but too short or whitespace-padded *is* a startup error.
  - Returns 503, never an empty feed, when the snapshot key is absent. An empty
    `FeedMessage` is a valid claim that nothing is cancelled; 503 makes MOTIS
    keep using the static timetable instead.
  - MOTIS side:
    ```yaml
    rt:
      - url: http://router:8080/api/gtfs-rt/trip-updates.pb
        headers:
          Authorization: Bearer <GTFS_RT_CREDENTIAL>
    ```

## Compose network segmentation（O7 / review_results.md P2-03）

`docker/docker-compose.yaml` 定義三個 network（見檔案底部 `networks:` 區塊
的完整說明）：

| Network | 成員 | 理由 |
|---|---|---|
| `frontend` | router, powersync | powersync 只需要透過 router 驗證 JWT（`jwks_uri`），與 edge proxy 對接；不需要 Redis。 |
| `backend` | router, functions, ingestor, loader, redis（+ test env 的 postgres） | 需要 Redis 或彼此協調的服務。 |
| `routing` | router, motis, motis-import, osrm-fetch | router 呼叫 `motis:8080`（路線規劃、附近站牌步行時間、geocode），MOTIS 反向讀 router 的 GTFS-RT 與 GBFS feed；其餘服務沒有理由碰到 MOTIS。 |

router 是唯一橫跨三個 network 的服務（它是 powersync、Redis、MOTIS 共同的
依賴）。

## PostgreSQL per-service roles

`migrations/2026-07-17-db-service-roles.sql` 是 operator 選用的 expand
步驟：建立 `router_svc` / `functions_svc` / `ingestor_svc` / `loader_svc` /
`powersync_svc` 五個角色，schema 層級 GRANT + `ALTER DEFAULT PRIVILEGES`
（不逐表列舉）。套用它**不影響**任何現有連線字串——`DATABASE_URL` /
`PS_DATABASE_URL` / `PS_SOURCE_DATABASE_URL` 照舊運作；把某個 service 的
連線字串換成新角色是後續、獨立的 operator 動作，且需要先手動
`ALTER ROLE ... PASSWORD '...'`（遷移檔本身用 `PASSWORD NULL`，不寫入任何
密碼）。

| Role | 權限範圍 |
|---|---|
| `router_svc` | target schema（`public`/`staging`）的 SELECT/INSERT/UPDATE/DELETE + 序列 USAGE/SELECT。router 會寫入 `firebase_device`/`firebase_route_subscription`/`firebase_arrival_reminder`（`services/api/firebase_store.go`），不是唯讀。不碰 `raw_tdx`。 |
| `functions_svc` | target schema 同上的讀寫，加 `raw_tdx` 的 SELECT（legacy prod 路徑的 boot-load 在未設定 `RAW_DATABASE_URL` 時會直接讀 `raw_tdx`）。 |
| `ingestor_svc` | 只有 `raw_tdx` 的 SELECT/INSERT/UPDATE/DELETE + 序列權限；不碰 target schema。 |
| `loader_svc` | target schema 的讀寫 + `raw_tdx` 的 SELECT（唯讀來源）。 |
| `powersync_svc` | `REPLICATION` role attribute（邏輯複製）+ target schema 的 SELECT。`PS_DATABASE_URL`（PowerSync 自己的 bucket-storage 資料庫）是完全不同的資料庫，這個遷移碰不到它。 |

套用方式（`target_schema=staging` 對應 staging，`public` 對應 prod）：

```bash
PGOPTIONS="-c search_path=staging" psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
    -v target_schema=staging -f migrations/2026-07-17-db-service-roles.sql
```

`raw_tdx` 的 GRANT 與 `target_schema` 無關（`raw_tdx` 是跨環境共用的單一
schema，見 `AGENTS.md`），因此對 `public` 與 `staging` 各套用一次時會重複
執行同樣的 `raw_tdx` GRANT，是無害的（`GRANT` 本身是幂等操作）。

### `GET /api/geocode`

- 地址／地標搜尋，代理 MOTIS 的 `/api/v1/geocode`（ADR-0022）。app 的行程規劃起訖點選擇先打這裡，空結果才 fallback Google Places。
- 參數：`text`（必填）、`lat`／`lon`（可選，把結果偏好到使用者附近；缺少或不合法就不送 bias）。
- 回應 `{"suggestions":[{"name","address","lat","lon","type"}]}`。座標隨建議一起回來，所以選定時不需要第二次 details 查詢——這是它跟 Google Places 路徑最大的差別。
- **上游失敗回 503，不是空的 200。** app 在錯誤時會 fallback，在空結果時也會 fallback，但「查不到」和「查不動」必須分得開，否則 MOTIS 掛掉會被記成「台灣沒有這個地方」。
- 速率限制每分鐘 60，比 `/api/search` 嚴：後者打 Postgres，這支打的是規劃引擎，用自動完成把 MOTIS 打爆會連帶讓路線規劃失效。
- `MAAS_BACKEND=tdx` 時整條路由不掛載（404）。

### MOTIS 服務的環境變數

`motis` 容器**不讀任何環境變數**——`motis server` 的組態全部來自 `motis import` 產出的資料目錄裡那份 `config.yml`。`motis-import` 只讀 `GTFS_RT_CREDENTIAL`，在匯入時把它替換進 `motis/config.yml` 的 `headers:`。這也是為什麼改 `motis/config.yml` 要重跑匯入才生效，重啟沒有用。

`MOTIS_PORT`（prod 發布到 loopback 的埠，預設 8082）、`MOTIS_MEM_LIMIT`、`MOTIS_IMPORT_MEM_LIMIT` 都是 compose 層的變數，不會進到容器裡。
