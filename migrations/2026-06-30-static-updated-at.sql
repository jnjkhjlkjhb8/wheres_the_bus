ALTER TABLE tra_fares ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE thsr_fares ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE bus_stations ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE bus_station_stop_map ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
