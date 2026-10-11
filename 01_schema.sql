-- =====================================================================
-- 01_schema.sql  |  Tables, AQI breakpoints, helper functions, seed data
-- Target: PostgreSQL 12+ (pgAdmin 4), database: aqi_db
-- Safe to re-run (idempotent).
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS aqi;
SET search_path = aqi, public;

-- ---------- Dimension: cities (the notebook reads this list) ----------
CREATE TABLE IF NOT EXISTS aqi.cities (
    city_id    SERIAL PRIMARY KEY,
    city_name  TEXT NOT NULL UNIQUE,
    state      TEXT,
    latitude   NUMERIC(9,6) NOT NULL,
    longitude  NUMERIC(9,6) NOT NULL,
    is_active  BOOLEAN NOT NULL DEFAULT TRUE
);

-- ---------- Dimension: monitoring stations (OpenAQ "locations") -------
CREATE TABLE IF NOT EXISTS aqi.stations (
    station_id    BIGINT PRIMARY KEY,               -- OpenAQ location id
    city_id       INT NOT NULL REFERENCES aqi.cities(city_id),
    station_name  TEXT,
    latitude      NUMERIC(9,6),
    longitude     NUMERIC(9,6),
    provider      TEXT,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_stations_city ON aqi.stations(city_id);

-- ---------- Fact: hourly readings (cleaned, standardised units) -------
-- Units after the Python transform:  ug/m3 for pm25, pm10, no2, so2, o3
--                                    mg/m3 for co
CREATE TABLE IF NOT EXISTS aqi.readings_hourly (
    station_id   BIGINT      NOT NULL REFERENCES aqi.stations(station_id),
    parameter    TEXT        NOT NULL CHECK (parameter IN ('pm25','pm10','no2','so2','co','o3')),
    ts_utc       TIMESTAMPTZ NOT NULL,              -- start of the hour
    value        NUMERIC(10,3) NOT NULL CHECK (value >= 0),
    unit         TEXT        NOT NULL,
    is_imputed   BOOLEAN     NOT NULL DEFAULT FALSE, -- filled by short-gap interpolation
    is_unhealthy BOOLEAN     NOT NULL DEFAULT FALSE, -- CPCB "Poor" or worse for this pollutant
    source       TEXT        NOT NULL DEFAULT 'openaq',
    ingested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (station_id, parameter, ts_utc)
);
CREATE INDEX IF NOT EXISTS ix_readings_ts        ON aqi.readings_hourly(ts_utc);
CREATE INDEX IF NOT EXISTS ix_readings_param_ts  ON aqi.readings_hourly(parameter, ts_utc);

-- ---------- Audit: one row per city per collector run -----------------
CREATE TABLE IF NOT EXISTS aqi.ingest_log (
    run_id         SERIAL PRIMARY KEY,
    run_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    city_name      TEXT NOT NULL,
    source         TEXT NOT NULL,
    rows_fetched   INT NOT NULL DEFAULT 0,
    rows_invalid   INT NOT NULL DEFAULT 0,   -- sentinel / negative / out-of-range -> NULL
    rows_missing   INT NOT NULL DEFAULT 0,   -- hours with no value after reindexing
    rows_imputed   INT NOT NULL DEFAULT 0,
    rows_loaded    INT NOT NULL DEFAULT 0,
    rows_unhealthy INT NOT NULL DEFAULT 0
);

-- ---------- Reference: India CPCB National AQI breakpoints ------------
-- Linear interpolation inside each band. Bands are continuous
-- (aqi_lo of a band = aqi_hi of the previous one).
CREATE TABLE IF NOT EXISTS aqi.breakpoints (
    parameter TEXT NOT NULL,
    band_no   INT  NOT NULL,
    category  TEXT NOT NULL,
    conc_lo   NUMERIC NOT NULL,
    conc_hi   NUMERIC NOT NULL,
    aqi_lo    INT NOT NULL,
    aqi_hi    INT NOT NULL,
    PRIMARY KEY (parameter, band_no)
);

TRUNCATE aqi.breakpoints;
INSERT INTO aqi.breakpoints (parameter, band_no, category, conc_lo, conc_hi, aqi_lo, aqi_hi)
SELECT p.parameter, b.band_no, b.category, p.cuts[b.band_no], p.cuts[b.band_no + 1], b.aqi_lo, b.aqi_hi
FROM (VALUES
    -- parameter, concentration cut-points (7 values -> 6 bands)
    ('pm25', ARRAY[0,  30,  60,  90, 120, 250,  380]::numeric[]),   -- ug/m3, 24h avg
    ('pm10', ARRAY[0,  50, 100, 250, 350, 430,  510]::numeric[]),   -- ug/m3, 24h avg
    ('no2',  ARRAY[0,  40,  80, 180, 280, 400,  500]::numeric[]),   -- ug/m3, 24h avg
    ('so2',  ARRAY[0,  40,  80, 380, 800,1600, 2000]::numeric[]),   -- ug/m3, 24h avg
    ('co',   ARRAY[0,   1,   2,  10,  17,  34,   50]::numeric[]),   -- mg/m3, max 8h avg
    ('o3',   ARRAY[0,  50, 100, 168, 208, 748, 1000]::numeric[])    -- ug/m3, max 8h avg
) AS p(parameter, cuts)
CROSS JOIN (VALUES
    (1,'Good',            0,  50),
    (2,'Satisfactory',   50, 100),
    (3,'Moderate',      100, 200),
    (4,'Poor',          200, 300),
    (5,'Very Poor',     300, 400),
    (6,'Severe',        400, 500)
) AS b(band_no, category, aqi_lo, aqi_hi);

-- ---------- Functions -------------------------------------------------
-- Sub-index for one pollutant concentration (NULL in -> NULL out, capped at 500)
CREATE OR REPLACE FUNCTION aqi.sub_index(p_parameter TEXT, p_conc NUMERIC)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT LEAST(500, ROUND(
             b.aqi_lo + (p_conc - b.conc_lo) * (b.aqi_hi - b.aqi_lo) / (b.conc_hi - b.conc_lo)))
    FROM aqi.breakpoints b
    WHERE b.parameter = p_parameter AND p_conc >= b.conc_lo
    ORDER BY b.conc_lo DESC
    LIMIT 1
$$;

CREATE OR REPLACE FUNCTION aqi.aqi_category(p_aqi NUMERIC)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_aqi IS NULL THEN NULL
                WHEN p_aqi <= 50  THEN 'Good'
                WHEN p_aqi <= 100 THEN 'Satisfactory'
                WHEN p_aqi <= 200 THEN 'Moderate'
                WHEN p_aqi <= 300 THEN 'Poor'
                WHEN p_aqi <= 400 THEN 'Very Poor'
                ELSE 'Severe' END
$$;

-- ---------- Seed: 10 major cities (edit freely) -----------------------
INSERT INTO aqi.cities (city_name, state, latitude, longitude) VALUES
 ('Delhi',     'Delhi',         28.6139, 77.2090),
 ('Mumbai',    'Maharashtra',   19.0760, 72.8777),
 ('Kolkata',   'West Bengal',   22.5726, 88.3639),
 ('Chennai',   'Tamil Nadu',    13.0827, 80.2707),
 ('Bengaluru', 'Karnataka',     12.9716, 77.5946),
 ('Hyderabad', 'Telangana',     17.3850, 78.4867),
 ('Ahmedabad', 'Gujarat',       23.0225, 72.5714),
 ('Pune',      'Maharashtra',   18.5204, 73.8567),
 ('Lucknow',   'Uttar Pradesh', 26.8467, 80.9462),
 ('Patna',     'Bihar',         25.5941, 85.1376)
ON CONFLICT (city_name) DO NOTHING;
