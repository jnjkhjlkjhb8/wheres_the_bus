-- migrations/baseline/0000-baseline.sql
--
-- The whole PostgreSQL schema as it runs in production, squashed from every
-- dated migration up to 2026-10-09. It is `pg_dump --schema-only` of the
-- cluster database on 2026-10-28, with three edits so it applies under the
-- CI psql 16 client and a superuser not named postgres:
--   * the PG18 \restrict / \unrestrict lines are removed;
--   * `OWNER TO postgres` lines are removed, so those objects belong to the
--     superuser that applies this file;
--   * the service roles below are created first, because pg_dump does not
--     dump roles. Passwords are set by bus-infra's
--     scripts/k3s-db-credentials.sh passwords.
--
-- Apply it once, as a superuser, to an empty database; it is not idempotent.
-- New schema changes go in new dated files next to this directory.

DO $roles$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['api_svc', 'bus_migrator', 'pipeline_svc', 'powersync_svc', 'realtime_svc', 'rider_svc'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I LOGIN', r);
        END IF;
    END LOOP;
END
$roles$;
ALTER ROLE powersync_svc WITH REPLICATION;

--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: raw_tdx; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA raw_tdx;



--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_stat_statements IS 'track planning and execution statistics of all SQL statements executed';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION postgis IS 'PostGIS geometry and geography spatial types and functions';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: stop; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.stop AS (
	stationuid text,
	stopname text,
	stopsequence smallint,
	positionlon double precision,
	positionlat double precision
);



--
-- Name: stop_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.stop_type AS (
	station_uid text,
	stop_name text,
	stop_sequence integer,
	"position" public.geometry(Point,4326)
);



--
-- Name: set_fetched_at(); Type: FUNCTION; Schema: raw_tdx; Owner: postgres
--

CREATE FUNCTION raw_tdx.set_fetched_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.fetched_at IS NULL THEN
    NEW.fetched_at := now();
  END IF;
  RETURN NEW;
END;
$$;



SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: bike_stations; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bike_stations (
    station_uid text NOT NULL,
    station_id text NOT NULL,
    name text NOT NULL,
    capacity integer DEFAULT 0 NOT NULL,
    service_type smallint DEFAULT 2 NOT NULL,
    city text NOT NULL,
    geom public.geometry(Point,4326),
    address text,
    updated_at timestamp with time zone
);


ALTER TABLE public.bike_stations OWNER TO bus_migrator;

--
-- Name: bus_display_stop_map; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_display_stop_map (
    route_uid text NOT NULL,
    direction smallint NOT NULL,
    stop_uid text NOT NULL,
    stop_sequence smallint NOT NULL,
    station_id text NOT NULL,
    stop_name text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bus_display_stop_map OWNER TO bus_migrator;

--
-- Name: bus_eta_prediction_error; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_eta_prediction_error (
    id bigint NOT NULL,
    sub_route_uid text NOT NULL,
    direction smallint NOT NULL,
    stop_uid text NOT NULL,
    source text NOT NULL,
    predicted_at timestamp with time zone NOT NULL,
    predicted_seconds integer NOT NULL,
    actual_seconds integer
);


ALTER TABLE public.bus_eta_prediction_error OWNER TO bus_migrator;

--
-- Name: bus_eta_prediction_error_id_seq; Type: SEQUENCE; Schema: public; Owner: bus_migrator
--

CREATE SEQUENCE public.bus_eta_prediction_error_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.bus_eta_prediction_error_id_seq OWNER TO bus_migrator;

--
-- Name: bus_eta_prediction_error_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: bus_migrator
--

ALTER SEQUENCE public.bus_eta_prediction_error_id_seq OWNED BY public.bus_eta_prediction_error.id;


--
-- Name: bus_operators; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_operators (
    operator_id text NOT NULL,
    authority_code text NOT NULL,
    operator_name text NOT NULL,
    operator_phone text,
    operator_url text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bus_operators OWNER TO bus_migrator;

--
-- Name: bus_schedule; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_schedule (
    id integer NOT NULL,
    sub_route_uid text NOT NULL,
    direction smallint NOT NULL,
    type boolean NOT NULL,
    tripid text,
    islowfloor boolean,
    stopsequence smallint,
    "stop_uid/MinHeadwayMins" text NOT NULL,
    "stop_name/MaxHeadwayMins" text NOT NULL,
    "arrival_time/StartTime" time without time zone NOT NULL,
    "departure_time/EndTime" time without time zone NOT NULL,
    service_day smallint,
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.bus_schedule OWNER TO bus_migrator;

--
-- Name: bus_schedule_id_seq; Type: SEQUENCE; Schema: public; Owner: bus_migrator
--

CREATE SEQUENCE public.bus_schedule_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.bus_schedule_id_seq OWNER TO bus_migrator;

--
-- Name: bus_schedule_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: bus_migrator
--

ALTER SEQUENCE public.bus_schedule_id_seq OWNED BY public.bus_schedule.id;


--
-- Name: bus_segment_time; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_segment_time (
    sub_route_uid text NOT NULL,
    direction smallint NOT NULL,
    from_stop_uid text NOT NULL,
    to_stop_uid text NOT NULL,
    secs integer NOT NULL,
    sample_count integer NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bus_segment_time OWNER TO bus_migrator;

--
-- Name: bus_static; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_static (
    sub_route_name text,
    route_name text,
    sub_route_uid text NOT NULL,
    route_uid text,
    city text,
    depart text,
    destin text,
    pb bytea NOT NULL,
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.bus_static OWNER TO bus_migrator;

--
-- Name: bus_station_group_members; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_station_group_members (
    station_uid text NOT NULL,
    group_uid text NOT NULL,
    station_id text NOT NULL,
    station_name text NOT NULL,
    city text NOT NULL,
    "position" public.geometry(Point,4326) NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bus_station_group_members OWNER TO bus_migrator;

--
-- Name: bus_station_groups; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_station_groups (
    group_uid text NOT NULL,
    group_id text NOT NULL,
    group_name text NOT NULL,
    city text NOT NULL,
    "position" public.geometry(Point,4326) NOT NULL,
    source text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bus_station_groups OWNER TO bus_migrator;

--
-- Name: bus_station_stop_map; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_station_stop_map (
    station_id text NOT NULL,
    sub_route_uid text NOT NULL,
    direction integer NOT NULL,
    route_name text,
    stop_uid text NOT NULL,
    stop_sequence integer,
    station_name text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bus_station_stop_map OWNER TO bus_migrator;

--
-- Name: bus_stations; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_stations (
    station_uid text NOT NULL,
    station_name text NOT NULL,
    city text NOT NULL,
    "position" public.geometry(Point,4326),
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.bus_stations OWNER TO bus_migrator;

--
-- Name: bus_stop_alias; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_stop_alias (
    sub_route_uid text NOT NULL,
    direction smallint NOT NULL,
    alias_stop_uid text NOT NULL,
    stop_uid text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.bus_stop_alias OWNER TO bus_migrator;

--
-- Name: bus_subroutes; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.bus_subroutes (
    sub_route_uid text NOT NULL,
    route_uid text NOT NULL,
    direction integer NOT NULL,
    route_name text,
    sub_route_name text,
    city text,
    depart text,
    destin text,
    geometry text,
    stops public.stop[],
    schedule jsonb,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    operators jsonb
);


ALTER TABLE public.bus_subroutes OWNER TO bus_migrator;

--
-- Name: feedback_message; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.feedback_message (
    id uuid NOT NULL,
    thread_id uuid NOT NULL,
    author text NOT NULL,
    body text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT feedback_message_author_check CHECK ((author = ANY (ARRAY['user'::text, 'ops'::text]))),
    CONSTRAINT feedback_message_body_check CHECK ((body <> ''::text))
);


ALTER TABLE public.feedback_message OWNER TO bus_migrator;

--
-- Name: TABLE feedback_message; Type: COMMENT; Schema: public; Owner: bus_migrator
--

COMMENT ON TABLE public.feedback_message IS 'One message on a feedback thread, from the rider who opened it or from ops replying.';


--
-- Name: feedback_thread; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.feedback_thread (
    id uuid NOT NULL,
    install_id text NOT NULL,
    category text NOT NULL,
    diagnostics jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT feedback_thread_category_check CHECK ((category = ANY (ARRAY['route_data'::text, 'eta'::text, 'crash'::text, 'suggestion'::text]))),
    CONSTRAINT feedback_thread_install_id_check CHECK ((install_id <> ''::text)),
    CONSTRAINT feedback_thread_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text])))
);


ALTER TABLE public.feedback_thread OWNER TO bus_migrator;

--
-- Name: TABLE feedback_thread; Type: COMMENT; Schema: public; Owner: bus_migrator
--

COMMENT ON TABLE public.feedback_thread IS 'One rider-submitted report: its category, the app diagnostics captured at submit time, and whether ops have finished with it.';


--
-- Name: firebase_arrival_reminder; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.firebase_arrival_reminder (
    reminder_id text NOT NULL,
    install_id text NOT NULL,
    route_type text NOT NULL,
    route_key text NOT NULL,
    stop_key text NOT NULL,
    direction text NOT NULL,
    lead_minutes smallint NOT NULL,
    fire_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    fired_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    plate text DEFAULT ''::text NOT NULL,
    claimed_at timestamp with time zone,
    alight_event text DEFAULT ''::text NOT NULL,
    CONSTRAINT firebase_arrival_reminder_check CHECK (((fired_at IS NULL) OR (status = 'fired'::text))),
    CONSTRAINT firebase_arrival_reminder_lead_minutes_check CHECK (((lead_minutes >= 1) AND (lead_minutes <= 120))),
    CONSTRAINT firebase_arrival_reminder_route_type_check CHECK ((route_type = ANY (ARRAY['bus'::text, 'mrt'::text, 'tra'::text, 'thsr'::text]))),
    CONSTRAINT firebase_arrival_reminder_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sending'::text, 'cancelled'::text, 'fired'::text, 'expired'::text])))
);


ALTER TABLE public.firebase_arrival_reminder OWNER TO bus_migrator;

--
-- Name: COLUMN firebase_arrival_reminder.claimed_at; Type: COMMENT; Schema: public; Owner: bus_migrator
--

COMMENT ON COLUMN public.firebase_arrival_reminder.claimed_at IS 'When the row last entered ''sending''; a ''sending'' row whose claimed_at is NULL or older than the dispatcher''s reclaim timeout is claimable again (crash recovery).';


--
-- Name: firebase_device; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.firebase_device (
    install_id text NOT NULL,
    install_secret_hash bytea NOT NULL,
    fcm_token text DEFAULT ''::text NOT NULL,
    platform text NOT NULL,
    app_version text DEFAULT ''::text NOT NULL,
    push_enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT firebase_device_check CHECK (((NOT push_enabled) OR (fcm_token <> ''::text))),
    CONSTRAINT firebase_device_install_secret_hash_check CHECK ((octet_length(install_secret_hash) = 32)),
    CONSTRAINT firebase_device_platform_check CHECK ((platform = ANY (ARRAY['android'::text, 'ios'::text])))
);


ALTER TABLE public.firebase_device OWNER TO bus_migrator;

--
-- Name: firebase_route_subscription; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.firebase_route_subscription (
    install_id text NOT NULL,
    route_type text NOT NULL,
    route_key text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT firebase_route_subscription_route_type_check CHECK ((route_type = ANY (ARRAY['bus'::text, 'mrt'::text, 'tra'::text, 'thsr'::text])))
);


ALTER TABLE public.firebase_route_subscription OWNER TO bus_migrator;

--
-- Name: gtfs_rt_bus_offset; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.gtfs_rt_bus_offset (
    run_id text NOT NULL,
    sub_route_uid text NOT NULL,
    direction integer NOT NULL,
    stop_uid text NOT NULL,
    offset_secs bigint NOT NULL
);


ALTER TABLE public.gtfs_rt_bus_offset OWNER TO bus_migrator;

--
-- Name: gtfs_rt_bus_trip; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.gtfs_rt_bus_trip (
    run_id text NOT NULL,
    trip_id text NOT NULL,
    direction_id integer NOT NULL,
    service_id text NOT NULL
);


ALTER TABLE public.gtfs_rt_bus_trip OWNER TO bus_migrator;

--
-- Name: gtfs_rt_rail_trip; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.gtfs_rt_rail_trip (
    run_id text NOT NULL,
    service_date date NOT NULL,
    train_no text NOT NULL,
    trip_id text NOT NULL,
    stations text[] NOT NULL
);


ALTER TABLE public.gtfs_rt_rail_trip OWNER TO bus_migrator;

--
-- Name: mrt_adjacency; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.mrt_adjacency (
    system text NOT NULL,
    line_id text NOT NULL,
    from_station_id text NOT NULL,
    to_station_id text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.mrt_adjacency OWNER TO bus_migrator;

--
-- Name: mrt_schedule; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.mrt_schedule (
    station_id text CONSTRAINT mrt_firstlast_stationid_not_null NOT NULL,
    lineid text CONSTRAINT mrt_firstlast_lineid_not_null NOT NULL,
    destinationstaionid text CONSTRAINT mrt_firstlast_destinationstaionid_not_null NOT NULL,
    destinationstationname text CONSTRAINT mrt_firstlast_destinationstationname_not_null NOT NULL,
    firsttraintime text CONSTRAINT mrt_firstlast_firsttraintime_not_null NOT NULL,
    lasttraintime text CONSTRAINT mrt_firstlast_lasttraintime_not_null NOT NULL,
    serviceday smallint CONSTRAINT mrt_firstlast_serviceday_not_null NOT NULL,
    system text CONSTRAINT mrt_firstlast_system_not_null NOT NULL,
    created_at timestamp with time zone,
    trip_head_sign text CONSTRAINT mrt_firstlast_trip_head_sign_not_null NOT NULL,
    id integer CONSTRAINT mrt_firstlast_id_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.mrt_schedule OWNER TO bus_migrator;

--
-- Name: mrt_firstlast_id_seq; Type: SEQUENCE; Schema: public; Owner: bus_migrator
--

CREATE SEQUENCE public.mrt_firstlast_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.mrt_firstlast_id_seq OWNER TO bus_migrator;

--
-- Name: mrt_firstlast_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: bus_migrator
--

ALTER SEQUENCE public.mrt_firstlast_id_seq OWNED BY public.mrt_schedule.id;


--
-- Name: mrt_journey_matrix; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.mrt_journey_matrix (
    id text NOT NULL,
    from_station_id text NOT NULL,
    to_station_id text NOT NULL,
    system text NOT NULL,
    fare_nt integer NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    travel_time_min integer DEFAULT 0 NOT NULL,
    half_fare_nt integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.mrt_journey_matrix OWNER TO bus_migrator;

--
-- Name: mrt_station; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.mrt_station (
    stationposition public.geometry(Point,4326) NOT NULL,
    system text NOT NULL,
    name text NOT NULL,
    city text NOT NULL,
    station_id text NOT NULL,
    bikeallowonholiday boolean NOT NULL,
    updated_at timestamp without time zone
);

ALTER TABLE ONLY public.mrt_station REPLICA IDENTITY FULL;


ALTER TABLE public.mrt_station OWNER TO bus_migrator;

--
-- Name: pipeline_runs; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.pipeline_runs (
    job text NOT NULL,
    run_date date NOT NULL,
    completed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pipeline_runs_job_check CHECK ((job <> ''::text))
);


ALTER TABLE public.pipeline_runs OWNER TO bus_migrator;

--
-- Name: TABLE pipeline_runs; Type: COMMENT; Schema: public; Owner: bus_migrator
--

COMMENT ON TABLE public.pipeline_runs IS 'Durable per-day completion marker for one nightly static pipeline stage (job), upserted only on full success; downstream stages poll it instead of coordinating by clock.';


--
-- Name: rail_shapes; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.rail_shapes (
    mode text NOT NULL,
    system text DEFAULT ''::text NOT NULL,
    line_id text NOT NULL,
    line_name jsonb,
    geom public.geometry(Geometry,4326) NOT NULL,
    updated_at timestamp with time zone,
    CONSTRAINT rail_shapes_mode_check CHECK ((mode = ANY (ARRAY['tra'::text, 'thsr'::text, 'metro'::text])))
);


ALTER TABLE public.rail_shapes OWNER TO bus_migrator;

--
-- Name: TABLE rail_shapes; Type: COMMENT; Schema: public; Owner: bus_migrator
--

COMMENT ON TABLE public.rail_shapes IS 'TRA/THSR/metro line shapes loaded from raw_tdx.{tra,thsr,metro}_shape, used by the router to clip a MaaS transit section to the real line geometry (transitPath).';


--
-- Name: route_alert_outbox; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.route_alert_outbox (
    id bigint NOT NULL,
    dedupe_key text NOT NULL,
    route_type text NOT NULL,
    route_key text NOT NULL,
    body text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    claimed_until timestamp with time zone,
    processed_at timestamp with time zone
);


ALTER TABLE public.route_alert_outbox OWNER TO bus_migrator;

--
-- Name: route_alert_outbox_id_seq; Type: SEQUENCE; Schema: public; Owner: bus_migrator
--

ALTER TABLE public.route_alert_outbox ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.route_alert_outbox_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.schema_migrations (
    filename text NOT NULL,
    sha256 text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_by text NOT NULL,
    CONSTRAINT schema_migrations_applied_by_check CHECK ((applied_by <> ''::text)),
    CONSTRAINT schema_migrations_sha256_check CHECK ((sha256 <> ''::text))
);


ALTER TABLE public.schema_migrations OWNER TO bus_migrator;

--
-- Name: TABLE schema_migrations; Type: COMMENT; Schema: public; Owner: bus_migrator
--

COMMENT ON TABLE public.schema_migrations IS 'Apply-history ledger written only by scripts/apply-migration.sh (ADR-0010); not a golang-migrate version table, no runner reads it.';


--
-- Name: search_vector; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.search_vector (
    type text CONSTRAINT serach_vector_type_not_null NOT NULL,
    uid text CONSTRAINT serach_vector_uid_not_null NOT NULL,
    name text CONSTRAINT serach_vector_name_not_null NOT NULL,
    city text CONSTRAINT serach_vector_city_not_null NOT NULL,
    depart text,
    destin text,
    geom public.geometry(Point,4326),
    updated_at timestamp without time zone,
    alias text
);


ALTER TABLE public.search_vector OWNER TO bus_migrator;

--
-- Name: static_build_seq; Type: SEQUENCE; Schema: public; Owner: bus_migrator
--

CREATE SEQUENCE public.static_build_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.static_build_seq OWNER TO bus_migrator;

--
-- Name: static_release; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.static_release (
    run_id text NOT NULL,
    build_seq bigint NOT NULL,
    gtfs_sha256 text NOT NULL,
    published_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.static_release OWNER TO bus_migrator;

--
-- Name: thsr_fares; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.thsr_fares (
    origin_station_id text CONSTRAINT thsr_originstationid_not_null NOT NULL,
    destination_station_id text CONSTRAINT thsr_destinationstationid_not_null NOT NULL,
    ticket_type integer CONSTRAINT thsr_tickettype_not_null NOT NULL,
    fare_class integer CONSTRAINT thsr_fareclass_not_null NOT NULL,
    cabin_class integer CONSTRAINT thsr_cabinclass_not_null NOT NULL,
    price integer CONSTRAINT thsr_price_not_null NOT NULL,
    updated_at timestamp without time zone
);


ALTER TABLE public.thsr_fares OWNER TO bus_migrator;

--
-- Name: thsr_stations; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.thsr_stations (
    station_id text NOT NULL,
    name text NOT NULL,
    city text NOT NULL,
    geom public.geometry(Point,4326) NOT NULL,
    stationcode text NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


ALTER TABLE public.thsr_stations OWNER TO bus_migrator;

--
-- Name: thsr_timetable; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.thsr_timetable (
    train_date date NOT NULL,
    trainno text NOT NULL,
    direction integer,
    starting_station_id text NOT NULL,
    starting_station_name text NOT NULL,
    ending_station_id text NOT NULL,
    ending_station_name text NOT NULL,
    stopsequence smallint,
    stationid text NOT NULL,
    stationname text,
    arrivaltime time without time zone,
    departuretime time without time zone,
    note text,
    updated_at timestamp with time zone,
    overnight boolean DEFAULT false NOT NULL
);


ALTER TABLE public.thsr_timetable OWNER TO bus_migrator;

--
-- Name: tra_fares; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.tra_fares (
    origin_station_id text NOT NULL,
    destination_station_id text NOT NULL,
    ticket_type text NOT NULL,
    price integer NOT NULL,
    updated_at timestamp without time zone
);


ALTER TABLE public.tra_fares OWNER TO bus_migrator;

--
-- Name: tra_stations; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.tra_stations (
    station_id text NOT NULL,
    name text NOT NULL,
    city text,
    geom public.geometry(Point,4326),
    updated_at timestamp with time zone
);


ALTER TABLE public.tra_stations OWNER TO bus_migrator;

--
-- Name: tra_timetable; Type: TABLE; Schema: public; Owner: bus_migrator
--

CREATE TABLE public.tra_timetable (
    train_date date NOT NULL,
    trainno text NOT NULL,
    direction integer,
    starting_station_id text NOT NULL,
    starting_station_name text NOT NULL,
    ending_station_id text NOT NULL,
    ending_station_name text NOT NULL,
    train_type_id text,
    train_type_code text,
    train_type_name text,
    tripline integer,
    stopsequence smallint,
    stationid text NOT NULL,
    stationname text,
    arrivaltime time without time zone,
    departuretime time without time zone,
    mask smallint,
    note text,
    updated_at timestamp with time zone
);


ALTER TABLE public.tra_timetable OWNER TO bus_migrator;

--
-- Name: bike_station; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bike_station (
    city text,
    stationuid text,
    stationid text,
    authorityid text,
    stationname jsonb,
    stationposition jsonb,
    stationaddress jsonb,
    stopdescription text,
    bikescapacity smallint,
    servicetype smallint,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bike_station OWNER TO bus_migrator;

--
-- Name: bus_dailytimetable; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_dailytimetable (
    city text,
    busdate timestamp with time zone,
    routeuid text,
    routeid text,
    routename jsonb,
    operatorid text,
    operatorno text,
    operatorcode text,
    subrouteuid text,
    subrouteid text,
    subroutename jsonb,
    direction smallint,
    timetables jsonb,
    updatetime timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_dailytimetable OWNER TO bus_migrator;

--
-- Name: bus_displaystopofroute; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_displaystopofroute (
    city text,
    routeuid text,
    routeid text,
    routename jsonb,
    direction smallint,
    stops jsonb,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL,
    landing_cycle text
);


ALTER TABLE raw_tdx.bus_displaystopofroute OWNER TO bus_migrator;

--
-- Name: bus_operator; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_operator (
    city text,
    providerid text,
    operatorid text,
    operatorname jsonb,
    operatorphone text,
    operatoremail text,
    operatorurl text,
    reservationurl text,
    reservationphone text,
    operatorcode text,
    authoritycode text,
    subauthoritycode text,
    operatorno text,
    updatetime timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_operator OWNER TO bus_migrator;

--
-- Name: bus_route; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_route (
    city text,
    routeuid text,
    routeid text,
    hassubroutes boolean,
    operators jsonb,
    authorityid text,
    providerid text,
    subroutes jsonb,
    busroutetype integer,
    routename jsonb,
    departurestopnamezh text,
    departurestopnameen text,
    destinationstopnamezh text,
    destinationstopnameen text,
    ticketpricedescriptionzh text,
    ticketpricedescriptionen text,
    farebufferzonedescriptionzh text,
    farebufferzonedescriptionen text,
    routemapimageurl text,
    citycode text,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_route OWNER TO bus_migrator;

--
-- Name: bus_routefare; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_routefare (
    city text,
    routeid text,
    routename text,
    operatorid text,
    operatorno text,
    subrouteid text,
    subroutename text,
    farepricingtype smallint,
    isfreebus smallint,
    isforallsubroutes smallint,
    sectionfares jsonb,
    stagefares jsonb,
    odfares jsonb,
    updatetime timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_routefare OWNER TO bus_migrator;

--
-- Name: bus_schedule; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_schedule (
    city text,
    routeuid text,
    routeid text,
    routename jsonb,
    subrouteuid text,
    subrouteid text,
    subroutename jsonb,
    direction smallint,
    operatorid text,
    operatorcode text,
    operatorno text,
    timetables jsonb,
    frequencys jsonb,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_schedule OWNER TO bus_migrator;

--
-- Name: bus_shape; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_shape (
    city text,
    routeuid text,
    routeid text,
    routename jsonb,
    subrouteuid text,
    subrouteid text,
    subroutename jsonb,
    direction smallint,
    geometry text,
    encodedpolyline text,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_shape OWNER TO bus_migrator;

--
-- Name: bus_station; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_station (
    city text,
    stationuid text,
    stationid text,
    stationname jsonb,
    stationposition jsonb,
    stationaddress text,
    stationgroupid text,
    stops jsonb,
    locationcitycode text,
    bearing text,
    updatetime text,
    versionid text,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_station OWNER TO bus_migrator;

--
-- Name: bus_stationgroup; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_stationgroup (
    city text,
    stationgroupuid text,
    stationgroupid text,
    stationgroupname jsonb,
    stationgroupposition jsonb,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_stationgroup OWNER TO bus_migrator;

--
-- Name: bus_stop; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_stop (
    city text,
    stopuid text,
    stopid text,
    authorityid text,
    stopname jsonb,
    stopposition jsonb,
    stopaddress text,
    bearing text,
    stationid text,
    stationgroupid text,
    stopdescription text,
    citycode text,
    locationcitycode text,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_stop OWNER TO bus_migrator;

--
-- Name: bus_stopofroute; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.bus_stopofroute (
    city text,
    routeuid text,
    routeid text,
    routename jsonb,
    operators jsonb,
    subrouteuid text,
    subrouteid text,
    subroutename jsonb,
    direction smallint,
    citycode text,
    stops jsonb,
    updatetime timestamp with time zone,
    versionid smallint,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.bus_stopofroute OWNER TO bus_migrator;

--
-- Name: landing_state; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.landing_state (
    table_name text NOT NULL,
    partition_column text DEFAULT ''::text NOT NULL,
    partition_value text DEFAULT ''::text NOT NULL,
    last_modified text NOT NULL,
    row_count bigint NOT NULL,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL,
    landing_cycle text,
    CONSTRAINT landing_state_check CHECK ((((partition_column = ''::text) AND (partition_value = ''::text)) OR ((partition_column <> ''::text) AND (partition_value <> ''::text)))),
    CONSTRAINT landing_state_last_modified_check CHECK ((last_modified <> ''::text)),
    CONSTRAINT landing_state_partition_column_check CHECK ((partition_column = ANY (ARRAY[''::text, 'city'::text, 'system'::text, 'traindate'::text]))),
    CONSTRAINT landing_state_row_count_check CHECK ((row_count >= 0)),
    CONSTRAINT landing_state_table_name_check CHECK ((table_name <> ''::text))
);


ALTER TABLE raw_tdx.landing_state OWNER TO bus_migrator;

--
-- Name: TABLE landing_state; Type: COMMENT; Schema: raw_tdx; Owner: bus_migrator
--

COMMENT ON TABLE raw_tdx.landing_state IS 'Durable validation metadata for conditional TDX raw landings; deploy before ingestor/loader binaries that read it.';


--
-- Name: COLUMN landing_state.landing_cycle; Type: COMMENT; Schema: raw_tdx; Owner: bus_migrator
--

COMMENT ON COLUMN raw_tdx.landing_state.landing_cycle IS 'Shared identity for every full or verified-304 partition touched by one ingestor run; NULL is legacy/unverified and is rejected by correlated loaders.';


--
-- Name: metro_frequency; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_frequency (
    system text,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    lineno text,
    lineid text,
    routeid text,
    traintype smallint,
    serviceday jsonb,
    operationtime jsonb,
    headways jsonb,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_frequency OWNER TO bus_migrator;

--
-- Name: metro_line; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_line (
    system text,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    lineno text,
    lineid text,
    linename jsonb,
    linesectionname jsonb,
    linecolor text,
    isbranch boolean,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_line OWNER TO bus_migrator;

--
-- Name: metro_linetransfer; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_linetransfer (
    system text,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    fromlineno text,
    fromlineid text,
    fromlinename jsonb,
    fromstationid text,
    fromstationname jsonb,
    tolineno text,
    tolineid text,
    tolinename jsonb,
    tostationid text,
    tostationname jsonb,
    isonsitetransfer smallint,
    transfertime smallint,
    transferdescription text,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_linetransfer OWNER TO bus_migrator;

--
-- Name: metro_odfare; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_odfare (
    system text,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    originstationid text,
    originstationname jsonb,
    destinationstationid text,
    destinationstationname jsonb,
    traintype smallint,
    fares jsonb,
    traveltime text,
    traveldistance text,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_odfare OWNER TO bus_migrator;

--
-- Name: metro_route; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_route (
    system text,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    routeid text,
    operatorcode text,
    routename jsonb,
    railroutetype smallint,
    lineno text,
    lineid text,
    direction smallint,
    startstationid text,
    startstationname jsonb,
    endstationid text,
    endstationname jsonb,
    traveltime integer,
    routelength double precision,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_route OWNER TO bus_migrator;

--
-- Name: metro_s2straveltime; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_s2straveltime (
    system text,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    lineno text,
    lineid text,
    routeid text,
    traintype smallint,
    traveltimes jsonb,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_s2straveltime OWNER TO bus_migrator;

--
-- Name: metro_schedule; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_schedule (
    system text,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    lineno text,
    lineid text,
    stationid text,
    stationname jsonb,
    tripheadsign text,
    destinationstaionid text,
    destinationstationname jsonb,
    traintype smallint,
    firsttraintime text,
    lasttraintime text,
    serviceday jsonb,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_schedule OWNER TO bus_migrator;

--
-- Name: metro_shape; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_shape (
    system text,
    lineno text,
    lineid text,
    linename jsonb,
    geometry text,
    encodedpolyline text,
    updatetime timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_shape OWNER TO bus_migrator;

--
-- Name: metro_station; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_station (
    system text,
    stationposition jsonb,
    locationcity text,
    locationcitycode text,
    locationtown text,
    locationtowncode text,
    stationuid text,
    stationid text,
    stationname jsonb,
    stationaddress text,
    bikeallowonholiday boolean,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_station OWNER TO bus_migrator;

--
-- Name: metro_stationexit; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_stationexit (
    system text,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    stationid text,
    stationname jsonb,
    exitid text,
    exitname jsonb,
    exitposition jsonb,
    locationdescription text,
    stair boolean,
    escalator smallint,
    elevator boolean,
    exitmapurls jsonb,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_stationexit OWNER TO bus_migrator;

--
-- Name: metro_stationofroute; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.metro_stationofroute (
    system text,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    versionid integer,
    lineno text,
    lineid text,
    routeid text,
    routename jsonb,
    direction smallint,
    stations jsonb,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.metro_stationofroute OWNER TO bus_migrator;

--
-- Name: rail_operator; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.rail_operator (
    providerid text,
    operatorid text,
    operatorname jsonb,
    operatorphone text,
    operatoremail text,
    operatorurl text,
    reservationurl text,
    reservationphone text,
    operatorcode text,
    authoritycode text,
    subauthoritycode text,
    operatorno text,
    updatetime timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.rail_operator OWNER TO bus_migrator;

--
-- Name: thsr_dailytimetable; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.thsr_dailytimetable (
    traindate timestamp with time zone,
    dailytraininfo jsonb,
    stoptimes jsonb,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.thsr_dailytimetable OWNER TO bus_migrator;

--
-- Name: thsr_odfare; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.thsr_odfare (
    originstationid text,
    destinationstationid text,
    fares jsonb,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.thsr_odfare OWNER TO bus_migrator;

--
-- Name: thsr_shape; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.thsr_shape (
    lineid text,
    linename jsonb,
    geometry text,
    encodedpolyline text,
    updatetime timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.thsr_shape OWNER TO bus_migrator;

--
-- Name: thsr_station; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.thsr_station (
    stationposition jsonb,
    locationcity text,
    locationcitycode text,
    locationtown text,
    locationtowncode text,
    stationuid text,
    stationid text,
    stationcode text,
    stationname jsonb,
    stationaddress text,
    stationphone text,
    operatorid text,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.thsr_station OWNER TO bus_migrator;

--
-- Name: thsr_stationexit; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.thsr_stationexit (
    stationid text,
    stationname jsonb,
    exitid text,
    exitname jsonb,
    exitposition jsonb,
    locationdescription text,
    stair boolean,
    escalator boolean,
    elevator boolean,
    exitmapurls jsonb,
    srcupdatetime timestamp with time zone,
    updatetime timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.thsr_stationexit OWNER TO bus_migrator;

--
-- Name: tra_dailytimetable; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.tra_dailytimetable (
    traindate text,
    dailytraininfo jsonb,
    stoptimes jsonb,
    updatetime timestamp with time zone,
    versionid smallint,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.tra_dailytimetable OWNER TO bus_migrator;

--
-- Name: tra_odfare; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.tra_odfare (
    originstationid text,
    originstationname jsonb,
    destinationstationid text,
    destinationstationname jsonb,
    direction smallint,
    fares jsonb,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.tra_odfare OWNER TO bus_migrator;

--
-- Name: tra_shape; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.tra_shape (
    lineno text,
    lineid text,
    linename jsonb,
    geometry text,
    encodedpolyline text,
    updatetime timestamp with time zone,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.tra_shape OWNER TO bus_migrator;

--
-- Name: tra_station; Type: TABLE; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TABLE raw_tdx.tra_station (
    stationposition jsonb,
    locationcity text,
    locationcitycode text,
    locationtown text,
    locationtowncode text,
    stationuid text,
    stationid text,
    stationcode text,
    stationname jsonb,
    stationaddress text,
    operatorid text,
    updatetime timestamp with time zone,
    versionid integer,
    fetched_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE raw_tdx.tra_station OWNER TO bus_migrator;

--
-- Name: bus_eta_prediction_error id; Type: DEFAULT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_eta_prediction_error ALTER COLUMN id SET DEFAULT nextval('public.bus_eta_prediction_error_id_seq'::regclass);


--
-- Name: bus_schedule id; Type: DEFAULT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_schedule ALTER COLUMN id SET DEFAULT nextval('public.bus_schedule_id_seq'::regclass);


--
-- Name: mrt_schedule id; Type: DEFAULT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.mrt_schedule ALTER COLUMN id SET DEFAULT nextval('public.mrt_firstlast_id_seq'::regclass);


--
-- Name: bike_stations bike_stations_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bike_stations
    ADD CONSTRAINT bike_stations_pkey PRIMARY KEY (station_uid);


--
-- Name: bus_display_stop_map bus_display_stop_map_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_display_stop_map
    ADD CONSTRAINT bus_display_stop_map_pkey PRIMARY KEY (route_uid, direction, stop_uid);


--
-- Name: bus_eta_prediction_error bus_eta_prediction_error_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_eta_prediction_error
    ADD CONSTRAINT bus_eta_prediction_error_pkey PRIMARY KEY (id);


--
-- Name: bus_operators bus_operators_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_operators
    ADD CONSTRAINT bus_operators_pkey PRIMARY KEY (operator_id, authority_code);


--
-- Name: bus_schedule bus_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_schedule
    ADD CONSTRAINT bus_schedule_pkey PRIMARY KEY (id);


--
-- Name: bus_segment_time bus_segment_time_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_segment_time
    ADD CONSTRAINT bus_segment_time_pkey PRIMARY KEY (sub_route_uid, direction, from_stop_uid, to_stop_uid);


--
-- Name: bus_static bus_static_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_static
    ADD CONSTRAINT bus_static_pkey PRIMARY KEY (sub_route_uid);


--
-- Name: bus_station_group_members bus_station_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_station_group_members
    ADD CONSTRAINT bus_station_group_members_pkey PRIMARY KEY (station_uid);


--
-- Name: bus_station_groups bus_station_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_station_groups
    ADD CONSTRAINT bus_station_groups_pkey PRIMARY KEY (group_uid);


--
-- Name: bus_station_stop_map bus_station_stop_map_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_station_stop_map
    ADD CONSTRAINT bus_station_stop_map_pkey PRIMARY KEY (sub_route_uid, stop_uid, direction);


--
-- Name: bus_stations bus_stations_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_stations
    ADD CONSTRAINT bus_stations_pkey PRIMARY KEY (station_uid);


--
-- Name: bus_stop_alias bus_stop_alias_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_stop_alias
    ADD CONSTRAINT bus_stop_alias_pkey PRIMARY KEY (sub_route_uid, direction, alias_stop_uid);


--
-- Name: bus_subroutes bus_subroutes_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_subroutes
    ADD CONSTRAINT bus_subroutes_pkey PRIMARY KEY (sub_route_uid, direction);


--
-- Name: feedback_message feedback_message_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.feedback_message
    ADD CONSTRAINT feedback_message_pkey PRIMARY KEY (id);


--
-- Name: feedback_thread feedback_thread_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.feedback_thread
    ADD CONSTRAINT feedback_thread_pkey PRIMARY KEY (id);


--
-- Name: firebase_arrival_reminder firebase_arrival_reminder_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.firebase_arrival_reminder
    ADD CONSTRAINT firebase_arrival_reminder_pkey PRIMARY KEY (reminder_id);


--
-- Name: firebase_device firebase_device_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.firebase_device
    ADD CONSTRAINT firebase_device_pkey PRIMARY KEY (install_id);


--
-- Name: firebase_route_subscription firebase_route_subscription_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.firebase_route_subscription
    ADD CONSTRAINT firebase_route_subscription_pkey PRIMARY KEY (install_id, route_type, route_key);


--
-- Name: mrt_adjacency mrt_adjacency_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.mrt_adjacency
    ADD CONSTRAINT mrt_adjacency_pkey PRIMARY KEY (system, from_station_id, to_station_id);


--
-- Name: mrt_schedule mrt_firstlast_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.mrt_schedule
    ADD CONSTRAINT mrt_firstlast_pkey PRIMARY KEY (id);


--
-- Name: mrt_journey_matrix mrt_journey_matrix_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.mrt_journey_matrix
    ADD CONSTRAINT mrt_journey_matrix_pkey PRIMARY KEY (id);


--
-- Name: pipeline_runs pipeline_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.pipeline_runs
    ADD CONSTRAINT pipeline_runs_pkey PRIMARY KEY (job, run_date);


--
-- Name: rail_shapes rail_shapes_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.rail_shapes
    ADD CONSTRAINT rail_shapes_pkey PRIMARY KEY (mode, system, line_id);


--
-- Name: route_alert_outbox route_alert_outbox_dedupe_key_key; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.route_alert_outbox
    ADD CONSTRAINT route_alert_outbox_dedupe_key_key UNIQUE (dedupe_key);


--
-- Name: route_alert_outbox route_alert_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.route_alert_outbox
    ADD CONSTRAINT route_alert_outbox_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (filename);


--
-- Name: search_vector serach_vector_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.search_vector
    ADD CONSTRAINT serach_vector_pkey PRIMARY KEY (type, uid, city);


--
-- Name: static_release static_release_build_seq_key; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.static_release
    ADD CONSTRAINT static_release_build_seq_key UNIQUE (build_seq);


--
-- Name: static_release static_release_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.static_release
    ADD CONSTRAINT static_release_pkey PRIMARY KEY (run_id);


--
-- Name: thsr_fares thsr_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.thsr_fares
    ADD CONSTRAINT thsr_pkey PRIMARY KEY (origin_station_id, destination_station_id, ticket_type, fare_class, cabin_class);


--
-- Name: thsr_stations thsr_stations_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.thsr_stations
    ADD CONSTRAINT thsr_stations_pkey PRIMARY KEY (station_id);


--
-- Name: thsr_timetable thsr_timetable_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.thsr_timetable
    ADD CONSTRAINT thsr_timetable_pkey PRIMARY KEY (train_date, trainno, stationid);


--
-- Name: tra_fares tra_fares_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.tra_fares
    ADD CONSTRAINT tra_fares_pkey PRIMARY KEY (origin_station_id, destination_station_id, ticket_type);


--
-- Name: tra_stations tra_stations_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.tra_stations
    ADD CONSTRAINT tra_stations_pkey PRIMARY KEY (station_id);


--
-- Name: tra_timetable tra_timetable_pkey; Type: CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.tra_timetable
    ADD CONSTRAINT tra_timetable_pkey PRIMARY KEY (train_date, trainno, stationid);


--
-- Name: landing_state landing_state_pkey; Type: CONSTRAINT; Schema: raw_tdx; Owner: bus_migrator
--

ALTER TABLE ONLY raw_tdx.landing_state
    ADD CONSTRAINT landing_state_pkey PRIMARY KEY (table_name, partition_column, partition_value);


--
-- Name: landing_state raw_landing_state_cycle_nonempty; Type: CHECK CONSTRAINT; Schema: raw_tdx; Owner: bus_migrator
--

ALTER TABLE raw_tdx.landing_state
    ADD CONSTRAINT raw_landing_state_cycle_nonempty CHECK (((landing_cycle IS NULL) OR (btrim(landing_cycle) <> ''::text))) NOT VALID;


--
-- Name: bike_stations_near; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bike_stations_near ON public.bike_stations USING gist (geom);


--
-- Name: bus_display_stop_map_route_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_display_stop_map_route_idx ON public.bus_display_stop_map USING btree (route_uid, direction, stop_sequence);


--
-- Name: bus_eta_prediction_error_lookup; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_eta_prediction_error_lookup ON public.bus_eta_prediction_error USING btree (sub_route_uid, direction, stop_uid, predicted_at);


--
-- Name: bus_eta_prediction_error_predicted_at; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_eta_prediction_error_predicted_at ON public.bus_eta_prediction_error USING btree (predicted_at);


--
-- Name: bus_schedule_route_lookup_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_schedule_route_lookup_idx ON public.bus_schedule USING btree (sub_route_uid, direction, service_day);


--
-- Name: bus_schedule_scan_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_schedule_scan_idx ON public.bus_schedule USING btree (sub_route_uid, direction, type, service_day, tripid, "stop_uid/MinHeadwayMins");


--
-- Name: bus_segment_time_subroute_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_segment_time_subroute_idx ON public.bus_segment_time USING btree (sub_route_uid, direction);


--
-- Name: bus_station_group_members_group_uid; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_station_group_members_group_uid ON public.bus_station_group_members USING btree (group_uid);


--
-- Name: bus_station_groups_city_group_id; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE UNIQUE INDEX bus_station_groups_city_group_id ON public.bus_station_groups USING btree (city, group_id);


--
-- Name: bus_station_groups_group_name; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_station_groups_group_name ON public.bus_station_groups USING btree (group_name);


--
-- Name: bus_station_groups_position; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_station_groups_position ON public.bus_station_groups USING gist ("position");


--
-- Name: bus_stations_near; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_stations_near ON public.bus_stations USING gist ("position");


--
-- Name: bus_stop_alias_sub_route_uid_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX bus_stop_alias_sub_route_uid_idx ON public.bus_stop_alias USING btree (sub_route_uid);


--
-- Name: feedback_message_thread_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX feedback_message_thread_idx ON public.feedback_message USING btree (thread_id, created_at);


--
-- Name: feedback_thread_install_recent_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX feedback_thread_install_recent_idx ON public.feedback_thread USING btree (install_id, created_at DESC);


--
-- Name: feedback_thread_open_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX feedback_thread_open_idx ON public.feedback_thread USING btree (created_at DESC) WHERE (status = 'open'::text);


--
-- Name: firebase_arrival_reminder_active_identity_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE UNIQUE INDEX firebase_arrival_reminder_active_identity_idx ON public.firebase_arrival_reminder USING btree (install_id, route_type, route_key, stop_key, direction, plate, alight_event) WHERE (status = ANY (ARRAY['pending'::text, 'sending'::text]));


--
-- Name: firebase_arrival_reminder_fire_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX firebase_arrival_reminder_fire_idx ON public.firebase_arrival_reminder USING btree (fire_at) WHERE ((status = 'pending'::text) AND (fire_at IS NOT NULL));


--
-- Name: firebase_arrival_reminder_owner_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX firebase_arrival_reminder_owner_idx ON public.firebase_arrival_reminder USING btree (install_id, status);


--
-- Name: firebase_arrival_reminder_retention_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX firebase_arrival_reminder_retention_idx ON public.firebase_arrival_reminder USING btree (updated_at) WHERE (status = ANY (ARRAY['cancelled'::text, 'fired'::text, 'expired'::text]));


--
-- Name: firebase_device_token_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX firebase_device_token_idx ON public.firebase_device USING btree (fcm_token) WHERE (fcm_token <> ''::text);


--
-- Name: firebase_route_subscription_route_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX firebase_route_subscription_route_idx ON public.firebase_route_subscription USING btree (route_type, route_key);


--
-- Name: gtfs_rt_bus_offset_run_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX gtfs_rt_bus_offset_run_idx ON public.gtfs_rt_bus_offset USING btree (run_id);


--
-- Name: gtfs_rt_bus_trip_run_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX gtfs_rt_bus_trip_run_idx ON public.gtfs_rt_bus_trip USING btree (run_id);


--
-- Name: gtfs_rt_rail_trip_run_date_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX gtfs_rt_rail_trip_run_date_idx ON public.gtfs_rt_rail_trip USING btree (run_id, service_date);


--
-- Name: idx_bike_stations_geog; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_bike_stations_geog ON public.bike_stations USING gist (((geom)::public.geography));


--
-- Name: idx_bssm_station_name; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_bssm_station_name ON public.bus_station_stop_map USING btree (station_name);


--
-- Name: idx_bus_static_route_uid; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_bus_static_route_uid ON public.bus_static USING btree (route_uid);


--
-- Name: idx_bus_station_groups_geog; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_bus_station_groups_geog ON public.bus_station_groups USING gist ((("position")::public.geography));


--
-- Name: idx_mapping_station_id; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_mapping_station_id ON public.bus_station_stop_map USING btree (station_id);


--
-- Name: idx_mrt_station_geog; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_mrt_station_geog ON public.mrt_station USING gist (((stationposition)::public.geography));


--
-- Name: idx_rail_shapes_geom; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_rail_shapes_geom ON public.rail_shapes USING gist (geom);


--
-- Name: idx_search_vector_alias_trgm; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_search_vector_alias_trgm ON public.search_vector USING gin (alias public.gin_trgm_ops);


--
-- Name: idx_search_vector_depart_trgm; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_search_vector_depart_trgm ON public.search_vector USING gin (depart public.gin_trgm_ops);


--
-- Name: idx_search_vector_destin_trgm; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_search_vector_destin_trgm ON public.search_vector USING gin (destin public.gin_trgm_ops);


--
-- Name: idx_search_vector_name_trgm; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_search_vector_name_trgm ON public.search_vector USING gin (name public.gin_trgm_ops);


--
-- Name: idx_thsr_stations_geog; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_thsr_stations_geog ON public.thsr_stations USING gist (((geom)::public.geography));


--
-- Name: idx_thsr_timetable_station; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_thsr_timetable_station ON public.thsr_timetable USING btree (stationid, train_date, arrivaltime);


--
-- Name: idx_tra_fares_destination_station_id; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_tra_fares_destination_station_id ON public.tra_fares USING btree (destination_station_id);


--
-- Name: idx_tra_stations_geog; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_tra_stations_geog ON public.tra_stations USING gist (((geom)::public.geography));


--
-- Name: idx_tra_timetable_ending_station_id; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_tra_timetable_ending_station_id ON public.tra_timetable USING btree (ending_station_id);


--
-- Name: idx_tra_timetable_starting_station_id; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_tra_timetable_starting_station_id ON public.tra_timetable USING btree (starting_station_id);


--
-- Name: idx_tra_timetable_station; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX idx_tra_timetable_station ON public.tra_timetable USING btree (stationid, train_date, arrivaltime);


--
-- Name: mrt_journey_matrix_natural_key; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE UNIQUE INDEX mrt_journey_matrix_natural_key ON public.mrt_journey_matrix USING btree (from_station_id, to_station_id, system);


--
-- Name: mrt_station_pkey; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE UNIQUE INDEX mrt_station_pkey ON public.mrt_station USING btree (station_id, system);


--
-- Name: mrt_stations_near; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX mrt_stations_near ON public.mrt_station USING gist (stationposition);


--
-- Name: route_alert_outbox_pending_idx; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX route_alert_outbox_pending_idx ON public.route_alert_outbox USING btree (id) WHERE (processed_at IS NULL);


--
-- Name: thsr_stations_near; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX thsr_stations_near ON public.thsr_stations USING gist (geom);


--
-- Name: tra_stations_near; Type: INDEX; Schema: public; Owner: bus_migrator
--

CREATE INDEX tra_stations_near ON public.tra_stations USING gist (geom);


--
-- Name: bus_dailytimetable_city_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX bus_dailytimetable_city_idx ON raw_tdx.bus_dailytimetable USING btree (city);


--
-- Name: bus_operator_city_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX bus_operator_city_idx ON raw_tdx.bus_operator USING btree (city);


--
-- Name: bus_route_city_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX bus_route_city_idx ON raw_tdx.bus_route USING btree (city);


--
-- Name: bus_routefare_city_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX bus_routefare_city_idx ON raw_tdx.bus_routefare USING btree (city);


--
-- Name: bus_schedule_city_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX bus_schedule_city_idx ON raw_tdx.bus_schedule USING btree (city);


--
-- Name: bus_shape_city_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX bus_shape_city_idx ON raw_tdx.bus_shape USING btree (city);


--
-- Name: bus_station_city_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX bus_station_city_idx ON raw_tdx.bus_station USING btree (city);


--
-- Name: bus_stationgroup_city_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX bus_stationgroup_city_idx ON raw_tdx.bus_stationgroup USING btree (city);


--
-- Name: bus_stopofroute_city_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX bus_stopofroute_city_idx ON raw_tdx.bus_stopofroute USING btree (city);


--
-- Name: idx_raw_thsr_dailytimetable_traindate; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX idx_raw_thsr_dailytimetable_traindate ON raw_tdx.thsr_dailytimetable USING btree (traindate);


--
-- Name: idx_raw_tra_dailytimetable_traindate; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX idx_raw_tra_dailytimetable_traindate ON raw_tdx.tra_dailytimetable USING btree (traindate);


--
-- Name: metro_frequency_system_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX metro_frequency_system_idx ON raw_tdx.metro_frequency USING btree (system);


--
-- Name: metro_line_system_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX metro_line_system_idx ON raw_tdx.metro_line USING btree (system);


--
-- Name: metro_route_system_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX metro_route_system_idx ON raw_tdx.metro_route USING btree (system);


--
-- Name: metro_stationexit_system_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX metro_stationexit_system_idx ON raw_tdx.metro_stationexit USING btree (system);


--
-- Name: metro_stationofroute_system_idx; Type: INDEX; Schema: raw_tdx; Owner: bus_migrator
--

CREATE INDEX metro_stationofroute_system_idx ON raw_tdx.metro_stationofroute USING btree (system);


--
-- Name: bike_station trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bike_station FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_dailytimetable trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_dailytimetable FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_displaystopofroute trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_displaystopofroute FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_operator trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_operator FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_route trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_route FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_routefare trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_routefare FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_schedule trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_schedule FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_shape trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_shape FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_station trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_station FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_stationgroup trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_stationgroup FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_stop trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_stop FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_stopofroute trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.bus_stopofroute FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_frequency trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_frequency FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_line trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_line FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_linetransfer trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_linetransfer FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_odfare trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_odfare FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_route trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_route FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_s2straveltime trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_s2straveltime FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_schedule trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_schedule FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_shape trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_shape FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_station trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_station FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_stationexit trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_stationexit FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: metro_stationofroute trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.metro_stationofroute FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: rail_operator trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.rail_operator FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: thsr_dailytimetable trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.thsr_dailytimetable FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: thsr_odfare trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.thsr_odfare FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: thsr_shape trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.thsr_shape FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: thsr_station trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.thsr_station FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: thsr_stationexit trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.thsr_stationexit FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: tra_dailytimetable trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.tra_dailytimetable FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: tra_odfare trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.tra_odfare FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: tra_shape trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.tra_shape FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: tra_station trg_set_fetched_at; Type: TRIGGER; Schema: raw_tdx; Owner: bus_migrator
--

CREATE TRIGGER trg_set_fetched_at BEFORE INSERT ON raw_tdx.tra_station FOR EACH ROW EXECUTE FUNCTION raw_tdx.set_fetched_at();


--
-- Name: bus_station_group_members bus_station_group_members_group_uid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.bus_station_group_members
    ADD CONSTRAINT bus_station_group_members_group_uid_fkey FOREIGN KEY (group_uid) REFERENCES public.bus_station_groups(group_uid) ON DELETE CASCADE;


--
-- Name: feedback_message feedback_message_thread_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.feedback_message
    ADD CONSTRAINT feedback_message_thread_id_fkey FOREIGN KEY (thread_id) REFERENCES public.feedback_thread(id) ON DELETE CASCADE;


--
-- Name: firebase_arrival_reminder firebase_arrival_reminder_install_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.firebase_arrival_reminder
    ADD CONSTRAINT firebase_arrival_reminder_install_id_fkey FOREIGN KEY (install_id) REFERENCES public.firebase_device(install_id) ON DELETE CASCADE;


--
-- Name: firebase_route_subscription firebase_route_subscription_install_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.firebase_route_subscription
    ADD CONSTRAINT firebase_route_subscription_install_id_fkey FOREIGN KEY (install_id) REFERENCES public.firebase_device(install_id) ON DELETE CASCADE;


--
-- Name: tra_timetable tra_daily_trains_ending_station_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.tra_timetable
    ADD CONSTRAINT tra_daily_trains_ending_station_id_fkey FOREIGN KEY (ending_station_id) REFERENCES public.tra_stations(station_id);


--
-- Name: tra_timetable tra_daily_trains_starting_station_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.tra_timetable
    ADD CONSTRAINT tra_daily_trains_starting_station_id_fkey FOREIGN KEY (starting_station_id) REFERENCES public.tra_stations(station_id);


--
-- Name: tra_fares tra_fares_destination_station_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.tra_fares
    ADD CONSTRAINT tra_fares_destination_station_id_fkey FOREIGN KEY (destination_station_id) REFERENCES public.tra_stations(station_id) ON DELETE CASCADE;


--
-- Name: tra_fares tra_fares_origin_station_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: bus_migrator
--

ALTER TABLE ONLY public.tra_fares
    ADD CONSTRAINT tra_fares_origin_station_id_fkey FOREIGN KEY (origin_station_id) REFERENCES public.tra_stations(station_id) ON DELETE CASCADE;


--
-- Name: powersync; Type: PUBLICATION; Schema: -; Owner: postgres
--

CREATE PUBLICATION powersync WITH (publish = 'insert, update, delete, truncate');



--
-- Name: powersync mrt_journey_matrix; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION powersync ADD TABLE ONLY public.mrt_journey_matrix;


--
-- Name: powersync mrt_schedule; Type: PUBLICATION TABLE; Schema: public; Owner: postgres
--

ALTER PUBLICATION powersync ADD TABLE ONLY public.mrt_schedule;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT ALL ON SCHEMA public TO bus_migrator;
GRANT USAGE ON SCHEMA public TO api_svc;
GRANT USAGE ON SCHEMA public TO realtime_svc;
GRANT USAGE ON SCHEMA public TO rider_svc;
GRANT USAGE ON SCHEMA public TO pipeline_svc;
GRANT USAGE ON SCHEMA public TO powersync_svc;


--
-- Name: SCHEMA raw_tdx; Type: ACL; Schema: -; Owner: postgres
--

GRANT ALL ON SCHEMA raw_tdx TO bus_migrator;
GRANT USAGE ON SCHEMA raw_tdx TO pipeline_svc;


--
-- Name: TABLE bike_stations; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bike_stations TO pipeline_svc;
GRANT SELECT ON TABLE public.bike_stations TO api_svc;
GRANT SELECT ON TABLE public.bike_stations TO realtime_svc;
GRANT SELECT ON TABLE public.bike_stations TO rider_svc;


--
-- Name: TABLE bus_display_stop_map; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_display_stop_map TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_display_stop_map TO api_svc;
GRANT SELECT ON TABLE public.bus_display_stop_map TO realtime_svc;
GRANT SELECT ON TABLE public.bus_display_stop_map TO rider_svc;


--
-- Name: TABLE bus_eta_prediction_error; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,DELETE,UPDATE ON TABLE public.bus_eta_prediction_error TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_eta_prediction_error TO api_svc;
GRANT SELECT,INSERT ON TABLE public.bus_eta_prediction_error TO realtime_svc;
GRANT SELECT ON TABLE public.bus_eta_prediction_error TO rider_svc;


--
-- Name: SEQUENCE bus_eta_prediction_error_id_seq; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,USAGE ON SEQUENCE public.bus_eta_prediction_error_id_seq TO pipeline_svc;
GRANT SELECT,USAGE ON SEQUENCE public.bus_eta_prediction_error_id_seq TO realtime_svc;


--
-- Name: TABLE bus_operators; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_operators TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_operators TO api_svc;
GRANT SELECT ON TABLE public.bus_operators TO realtime_svc;
GRANT SELECT ON TABLE public.bus_operators TO rider_svc;


--
-- Name: TABLE bus_schedule; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_schedule TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_schedule TO api_svc;
GRANT SELECT ON TABLE public.bus_schedule TO realtime_svc;
GRANT SELECT ON TABLE public.bus_schedule TO rider_svc;


--
-- Name: SEQUENCE bus_schedule_id_seq; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,USAGE ON SEQUENCE public.bus_schedule_id_seq TO pipeline_svc;


--
-- Name: TABLE bus_segment_time; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_segment_time TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_segment_time TO api_svc;
GRANT SELECT ON TABLE public.bus_segment_time TO realtime_svc;
GRANT SELECT ON TABLE public.bus_segment_time TO rider_svc;


--
-- Name: TABLE bus_static; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_static TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_static TO api_svc;
GRANT SELECT ON TABLE public.bus_static TO realtime_svc;
GRANT SELECT ON TABLE public.bus_static TO rider_svc;


--
-- Name: TABLE bus_station_group_members; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_station_group_members TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_station_group_members TO api_svc;
GRANT SELECT ON TABLE public.bus_station_group_members TO realtime_svc;
GRANT SELECT ON TABLE public.bus_station_group_members TO rider_svc;


--
-- Name: TABLE bus_station_groups; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_station_groups TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_station_groups TO api_svc;
GRANT SELECT ON TABLE public.bus_station_groups TO realtime_svc;
GRANT SELECT ON TABLE public.bus_station_groups TO rider_svc;


--
-- Name: TABLE bus_station_stop_map; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_station_stop_map TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_station_stop_map TO api_svc;
GRANT SELECT ON TABLE public.bus_station_stop_map TO realtime_svc;
GRANT SELECT ON TABLE public.bus_station_stop_map TO rider_svc;


--
-- Name: TABLE bus_stations; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_stations TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_stations TO api_svc;
GRANT SELECT ON TABLE public.bus_stations TO realtime_svc;
GRANT SELECT ON TABLE public.bus_stations TO rider_svc;


--
-- Name: TABLE bus_stop_alias; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_stop_alias TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_stop_alias TO api_svc;
GRANT SELECT ON TABLE public.bus_stop_alias TO realtime_svc;
GRANT SELECT ON TABLE public.bus_stop_alias TO rider_svc;


--
-- Name: TABLE bus_subroutes; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.bus_subroutes TO pipeline_svc;
GRANT SELECT ON TABLE public.bus_subroutes TO api_svc;
GRANT SELECT ON TABLE public.bus_subroutes TO realtime_svc;
GRANT SELECT ON TABLE public.bus_subroutes TO rider_svc;


--
-- Name: TABLE feedback_message; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.feedback_message TO rider_svc;


--
-- Name: TABLE feedback_thread; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.feedback_thread TO rider_svc;


--
-- Name: TABLE firebase_arrival_reminder; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.firebase_arrival_reminder TO rider_svc;


--
-- Name: TABLE firebase_device; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.firebase_device TO rider_svc;


--
-- Name: TABLE firebase_route_subscription; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.firebase_route_subscription TO rider_svc;


--
-- Name: TABLE gtfs_rt_bus_offset; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.gtfs_rt_bus_offset TO pipeline_svc;
GRANT SELECT ON TABLE public.gtfs_rt_bus_offset TO api_svc;
GRANT SELECT ON TABLE public.gtfs_rt_bus_offset TO realtime_svc;
GRANT SELECT ON TABLE public.gtfs_rt_bus_offset TO rider_svc;


--
-- Name: TABLE gtfs_rt_bus_trip; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.gtfs_rt_bus_trip TO pipeline_svc;
GRANT SELECT ON TABLE public.gtfs_rt_bus_trip TO api_svc;
GRANT SELECT ON TABLE public.gtfs_rt_bus_trip TO realtime_svc;
GRANT SELECT ON TABLE public.gtfs_rt_bus_trip TO rider_svc;


--
-- Name: TABLE gtfs_rt_rail_trip; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.gtfs_rt_rail_trip TO pipeline_svc;
GRANT SELECT ON TABLE public.gtfs_rt_rail_trip TO api_svc;
GRANT SELECT ON TABLE public.gtfs_rt_rail_trip TO realtime_svc;
GRANT SELECT ON TABLE public.gtfs_rt_rail_trip TO rider_svc;


--
-- Name: TABLE mrt_adjacency; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.mrt_adjacency TO pipeline_svc;
GRANT SELECT ON TABLE public.mrt_adjacency TO api_svc;
GRANT SELECT ON TABLE public.mrt_adjacency TO realtime_svc;
GRANT SELECT ON TABLE public.mrt_adjacency TO rider_svc;


--
-- Name: TABLE mrt_schedule; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.mrt_schedule TO pipeline_svc;
GRANT SELECT ON TABLE public.mrt_schedule TO api_svc;
GRANT SELECT ON TABLE public.mrt_schedule TO realtime_svc;
GRANT SELECT ON TABLE public.mrt_schedule TO rider_svc;
GRANT SELECT ON TABLE public.mrt_schedule TO powersync_svc;


--
-- Name: SEQUENCE mrt_firstlast_id_seq; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,USAGE ON SEQUENCE public.mrt_firstlast_id_seq TO pipeline_svc;


--
-- Name: TABLE mrt_journey_matrix; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.mrt_journey_matrix TO pipeline_svc;
GRANT SELECT ON TABLE public.mrt_journey_matrix TO api_svc;
GRANT SELECT ON TABLE public.mrt_journey_matrix TO realtime_svc;
GRANT SELECT ON TABLE public.mrt_journey_matrix TO rider_svc;
GRANT SELECT ON TABLE public.mrt_journey_matrix TO powersync_svc;


--
-- Name: TABLE mrt_station; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.mrt_station TO pipeline_svc;
GRANT SELECT ON TABLE public.mrt_station TO api_svc;
GRANT SELECT ON TABLE public.mrt_station TO realtime_svc;
GRANT SELECT ON TABLE public.mrt_station TO rider_svc;


--
-- Name: TABLE pipeline_runs; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pipeline_runs TO pipeline_svc;
GRANT SELECT ON TABLE public.pipeline_runs TO api_svc;
GRANT SELECT ON TABLE public.pipeline_runs TO realtime_svc;
GRANT SELECT ON TABLE public.pipeline_runs TO rider_svc;


--
-- Name: TABLE rail_shapes; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rail_shapes TO pipeline_svc;
GRANT SELECT ON TABLE public.rail_shapes TO api_svc;
GRANT SELECT ON TABLE public.rail_shapes TO realtime_svc;
GRANT SELECT ON TABLE public.rail_shapes TO rider_svc;


--
-- Name: TABLE route_alert_outbox; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT ON TABLE public.route_alert_outbox TO realtime_svc;
GRANT SELECT,DELETE,UPDATE ON TABLE public.route_alert_outbox TO rider_svc;
GRANT SELECT ON TABLE public.route_alert_outbox TO api_svc;
GRANT SELECT ON TABLE public.route_alert_outbox TO pipeline_svc;


--
-- Name: SEQUENCE route_alert_outbox_id_seq; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,USAGE ON SEQUENCE public.route_alert_outbox_id_seq TO realtime_svc;


--
-- Name: TABLE search_vector; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.search_vector TO pipeline_svc;
GRANT SELECT ON TABLE public.search_vector TO api_svc;
GRANT SELECT ON TABLE public.search_vector TO realtime_svc;
GRANT SELECT ON TABLE public.search_vector TO rider_svc;


--
-- Name: SEQUENCE static_build_seq; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,USAGE ON SEQUENCE public.static_build_seq TO pipeline_svc;


--
-- Name: TABLE static_release; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.static_release TO pipeline_svc;
GRANT SELECT ON TABLE public.static_release TO api_svc;
GRANT SELECT ON TABLE public.static_release TO realtime_svc;
GRANT SELECT ON TABLE public.static_release TO rider_svc;


--
-- Name: TABLE thsr_fares; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.thsr_fares TO pipeline_svc;
GRANT SELECT ON TABLE public.thsr_fares TO api_svc;
GRANT SELECT ON TABLE public.thsr_fares TO realtime_svc;
GRANT SELECT ON TABLE public.thsr_fares TO rider_svc;


--
-- Name: TABLE thsr_stations; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.thsr_stations TO pipeline_svc;
GRANT SELECT ON TABLE public.thsr_stations TO api_svc;
GRANT SELECT ON TABLE public.thsr_stations TO realtime_svc;
GRANT SELECT ON TABLE public.thsr_stations TO rider_svc;


--
-- Name: TABLE thsr_timetable; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.thsr_timetable TO pipeline_svc;
GRANT SELECT ON TABLE public.thsr_timetable TO api_svc;
GRANT SELECT ON TABLE public.thsr_timetable TO realtime_svc;
GRANT SELECT ON TABLE public.thsr_timetable TO rider_svc;


--
-- Name: TABLE tra_fares; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tra_fares TO pipeline_svc;
GRANT SELECT ON TABLE public.tra_fares TO api_svc;
GRANT SELECT ON TABLE public.tra_fares TO realtime_svc;
GRANT SELECT ON TABLE public.tra_fares TO rider_svc;


--
-- Name: TABLE tra_stations; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tra_stations TO pipeline_svc;
GRANT SELECT ON TABLE public.tra_stations TO api_svc;
GRANT SELECT ON TABLE public.tra_stations TO realtime_svc;
GRANT SELECT ON TABLE public.tra_stations TO rider_svc;


--
-- Name: TABLE tra_timetable; Type: ACL; Schema: public; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tra_timetable TO pipeline_svc;
GRANT SELECT ON TABLE public.tra_timetable TO api_svc;
GRANT SELECT ON TABLE public.tra_timetable TO realtime_svc;
GRANT SELECT ON TABLE public.tra_timetable TO rider_svc;


--
-- Name: TABLE bike_station; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bike_station TO pipeline_svc;


--
-- Name: TABLE bus_dailytimetable; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_dailytimetable TO pipeline_svc;


--
-- Name: TABLE bus_displaystopofroute; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_displaystopofroute TO pipeline_svc;


--
-- Name: TABLE bus_operator; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_operator TO pipeline_svc;


--
-- Name: TABLE bus_route; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_route TO pipeline_svc;


--
-- Name: TABLE bus_routefare; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_routefare TO pipeline_svc;


--
-- Name: TABLE bus_schedule; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_schedule TO pipeline_svc;


--
-- Name: TABLE bus_shape; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_shape TO pipeline_svc;


--
-- Name: TABLE bus_station; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_station TO pipeline_svc;


--
-- Name: TABLE bus_stationgroup; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_stationgroup TO pipeline_svc;


--
-- Name: TABLE bus_stop; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_stop TO pipeline_svc;


--
-- Name: TABLE bus_stopofroute; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.bus_stopofroute TO pipeline_svc;


--
-- Name: TABLE landing_state; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.landing_state TO pipeline_svc;


--
-- Name: TABLE metro_frequency; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_frequency TO pipeline_svc;


--
-- Name: TABLE metro_line; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_line TO pipeline_svc;


--
-- Name: TABLE metro_linetransfer; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_linetransfer TO pipeline_svc;


--
-- Name: TABLE metro_odfare; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_odfare TO pipeline_svc;


--
-- Name: TABLE metro_route; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_route TO pipeline_svc;


--
-- Name: TABLE metro_s2straveltime; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_s2straveltime TO pipeline_svc;


--
-- Name: TABLE metro_schedule; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_schedule TO pipeline_svc;


--
-- Name: TABLE metro_shape; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_shape TO pipeline_svc;


--
-- Name: TABLE metro_station; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_station TO pipeline_svc;


--
-- Name: TABLE metro_stationexit; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_stationexit TO pipeline_svc;


--
-- Name: TABLE metro_stationofroute; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.metro_stationofroute TO pipeline_svc;


--
-- Name: TABLE rail_operator; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.rail_operator TO pipeline_svc;


--
-- Name: TABLE thsr_dailytimetable; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.thsr_dailytimetable TO pipeline_svc;


--
-- Name: TABLE thsr_odfare; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.thsr_odfare TO pipeline_svc;


--
-- Name: TABLE thsr_shape; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.thsr_shape TO pipeline_svc;


--
-- Name: TABLE thsr_station; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.thsr_station TO pipeline_svc;


--
-- Name: TABLE thsr_stationexit; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.thsr_stationexit TO pipeline_svc;


--
-- Name: TABLE tra_dailytimetable; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.tra_dailytimetable TO pipeline_svc;


--
-- Name: TABLE tra_odfare; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.tra_odfare TO pipeline_svc;


--
-- Name: TABLE tra_shape; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.tra_shape TO pipeline_svc;


--
-- Name: TABLE tra_station; Type: ACL; Schema: raw_tdx; Owner: bus_migrator
--

GRANT SELECT,INSERT,DELETE,TRUNCATE,UPDATE ON TABLE raw_tdx.tra_station TO pipeline_svc;


--
-- PostgreSQL database dump complete
--
