import json
import os
import numpy as np
import pandas as pd
import psycopg2
from xgboost import XGBRegressor
from sklearn.preprocessing import LabelEncoder

DB_URL = os.environ["DATABASE_URL"]

def load_data(conn):
    crossings = pd.read_sql("""
        WITH ordered AS (
            SELECT sub_route_uid, direction, stop_uid, city, hour, day_of_week,
                   is_holiday, temperature, precipitation, wind_speed, humidity,
                   stop_sequence, total_stops, plate_numb, bus_speed, bus_distance_m,
                   estimate, recorded_at,
                   LAG(estimate)    OVER w AS prev_est,
                   LAG(recorded_at) OVER w AS prev_at
            FROM bus_eta_history
            WINDOW w AS (PARTITION BY sub_route_uid, direction, stop_uid ORDER BY recorded_at)
        )
        SELECT sub_route_uid, direction, stop_uid, city, hour, day_of_week,
               is_holiday, temperature, precipitation, wind_speed, humidity,
               stop_sequence, total_stops, plate_numb, bus_speed, bus_distance_m,
               prev_at + make_interval(secs =>
                   EXTRACT(EPOCH FROM recorded_at - prev_at) *
                   prev_est::float / (prev_est - estimate)::float
               ) AS crossing_at
        FROM ordered
        WHERE prev_est > 0 AND estimate <= 0
          AND EXTRACT(EPOCH FROM recorded_at - prev_at) < 300
    """, conn)

    offsets = pd.read_sql("""
        WITH linked AS (
            SELECT m.sub_route_uid, m.direction, m.stop_uid, m.stop_sequence,
                   LAG(m.stop_uid) OVER w AS prev_stop_uid,
                   count(*) OVER (PARTITION BY m.sub_route_uid, m.direction) AS stop_count
            FROM bus_station_stop_map m
            WINDOW w AS (PARTITION BY m.sub_route_uid, m.direction ORDER BY m.stop_sequence)
        ), accumulated AS (
            SELECT l.sub_route_uid, l.direction, l.stop_uid,
                   SUM(COALESCE(g.secs, 0)) OVER (PARTITION BY l.sub_route_uid, l.direction
                                                  ORDER BY l.stop_sequence
                                                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS offset_seconds,
                   (l.stop_count > 1
                    AND BOOL_AND(l.prev_stop_uid IS NULL OR g.secs IS NOT NULL)
                        OVER (PARTITION BY l.sub_route_uid, l.direction)) AS complete
            FROM linked l
            LEFT JOIN bus_segment_time g
              ON g.sub_route_uid = l.sub_route_uid
             AND g.direction     = l.direction
             AND g.from_stop_uid = l.prev_stop_uid
             AND g.to_stop_uid   = l.stop_uid
        )
        SELECT sub_route_uid, direction, stop_uid, offset_seconds
        FROM accumulated WHERE complete
    """, conn)

    schedules = pd.read_sql("""
        SELECT DISTINCT ON (sub_route_uid, direction, tripid)
               sub_route_uid, direction, service_day,
               "arrival_time/StartTime" AS dep_time
        FROM bus_schedule
        WHERE type = false
        ORDER BY sub_route_uid, direction, tripid, stopsequence
    """, conn)

    return crossings, offsets, schedules

def compute_travel_seconds(crossings, schedules):
    schedules = schedules.assign(
        dep_secs=schedules["dep_time"].map(
            lambda t: t.hour * 3600 + t.minute * 60 + t.second
        )
    ).sort_values("dep_secs")

    sched_map = {}
    for (uid, direction), grp in schedules.groupby(["sub_route_uid", "direction"]):
        sched_map[(uid, direction)] = (
            grp["dep_secs"].values,
            grp["service_day"].values,
        )

    rows = []
    for _, c in crossings.iterrows():
        key = (c["sub_route_uid"], c["direction"])
        if key not in sched_map:
            continue
        times, masks = sched_map[key]
        # service_day is a Monday=bit0..Sunday=bit6 mask; day_of_week follows
        # Go's time.Weekday() (Sunday=0).
        day_bit = 1 << ((int(c["day_of_week"]) + 6) % 7)
        tod = c["crossing_at"].hour * 3600 + c["crossing_at"].minute * 60 + c["crossing_at"].second
        serving = (masks & day_bit) != 0
        before = times[serving & (times <= tod)]
        if len(before) == 0:
            continue
        dep_secs = before[-1]
        travel = tod - dep_secs
        if travel < 0 or travel > 7200:
            continue
        rows.append({**c.to_dict(), "actual_travel": travel})
    return pd.DataFrame(rows)

def main():
    conn = psycopg2.connect(DB_URL)
    crossings, offsets, schedules = load_data(conn)
    conn.close()

    df = compute_travel_seconds(crossings, schedules)
    if df.empty:
        raise SystemExit(
            f"no matched arrivals: {len(crossings)} crossings, "
            f"{len(schedules)} schedule trips, {len(offsets)} stop offsets"
        )
    df = df.merge(offsets, on=["sub_route_uid", "direction", "stop_uid"], how="left")
    df = df.dropna(subset=["offset_seconds"])
    df["delay_seconds"] = df["actual_travel"] - df["offset_seconds"]
    df = df[df["delay_seconds"].abs() <= 3600]

    city_enc = LabelEncoder()
    plate_enc = LabelEncoder()
    df["city_encoded"] = city_enc.fit_transform(df["city"])
    df["plate_numb"] = df["plate_numb"].fillna("__UNKNOWN__")
    df["plate_encoded"] = plate_enc.fit_transform(df["plate_numb"])
    df.loc[df["plate_numb"] == "__UNKNOWN__", "plate_encoded"] = -1

    df["stop_sequence_ratio"] = df["stop_sequence"] / df["total_stops"].replace(0, 1)
    df["temperature"]   = df["temperature"].fillna(df["temperature"].mean())
    df["wind_speed"]    = df["wind_speed"].fillna(df["wind_speed"].mean())
    df["humidity"]      = df["humidity"].fillna(df["humidity"].mean())
    df["precipitation"] = df["precipitation"].fillna(0)
    df["bus_speed"]     = df["bus_speed"].fillna(-1)
    df["bus_distance_m"] = df["bus_distance_m"].fillna(-1)

    features = [
        "hour", "day_of_week", "is_holiday", "temperature", "precipitation",
        "wind_speed", "humidity", "direction", "stop_sequence", "total_stops",
        "stop_sequence_ratio", "city_encoded", "plate_encoded",
        "bus_speed", "bus_distance_m",
    ]
    X = df[features].astype(float)
    y = df["delay_seconds"]

    model = XGBRegressor(
        n_estimators=300, max_depth=6, learning_rate=0.05,
        subsample=0.8, colsample_bytree=0.8, objective="reg:squarederror",
    )
    model.fit(X, y)

    os.makedirs("model", exist_ok=True)
    model.save_model("model/bus_eta.json")

    encoders = {
        "city": {cls: int(i) for i, cls in enumerate(city_enc.classes_)},
        "plate_numb": {cls: int(i) for i, cls in enumerate(plate_enc.classes_)},
    }
    with open("model/bus_eta_encoders.json", "w") as f:
        json.dump(encoders, f, ensure_ascii=False)

    print(f"Trained on {len(df)} samples. Model saved to model/bus_eta.json")

if __name__ == "__main__":
    main()
