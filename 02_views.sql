-- =====================================================================
-- 02_views.sql  |  Transform layer: hourly -> daily -> city AQI
-- Days are Indian Standard Time (Asia/Kolkata) calendar days.
-- CPCB method: PM2.5, PM10, NO2, SO2 use 24h average;
--              CO, O3 use the maximum rolling 8h average.
-- A pollutant-day needs >= 16 valid hours; a city-day AQI needs
-- >= 3 pollutants, at least one of them PM2.5 or PM10.
-- =====================================================================
SET search_path = aqi, public;

-- 1) Rolling 8h average per station (used for CO and O3)
CREATE OR REPLACE VIEW aqi.v_station_rolling8h AS
SELECT station_id, parameter, ts_utc,
       AVG(value) OVER w AS avg_8h,
       COUNT(*)   OVER w AS n_hours
FROM aqi.readings_hourly
WHERE parameter IN ('co','o3')
WINDOW w AS (PARTITION BY station_id, parameter ORDER BY ts_utc
             RANGE BETWEEN INTERVAL '7 hours' PRECEDING AND CURRENT ROW);

-- 2) Station-level daily value per pollutant
CREATE OR REPLACE VIEW aqi.v_station_daily AS
WITH base AS (
    SELECT station_id, parameter,
           (ts_utc AT TIME ZONE 'Asia/Kolkata')::date AS obs_date,
           COUNT(*)::int AS n_hours,
           AVG(value)    AS daily_avg
    FROM aqi.readings_hourly
    WHERE parameter IN ('pm25','pm10','no2','so2')
    GROUP BY 1,2,3
), r8 AS (
    SELECT station_id, parameter,
           (ts_utc AT TIME ZONE 'Asia/Kolkata')::date AS obs_date,
           COUNT(*)::int AS n_hours,
           MAX(avg_8h) FILTER (WHERE n_hours >= 6) AS daily_avg   -- need 6 of 8 hours
    FROM aqi.v_station_rolling8h
    GROUP BY 1,2,3
)
SELECT * FROM base WHERE n_hours >= 16
UNION ALL
SELECT * FROM r8   WHERE n_hours >= 16 AND daily_avg IS NOT NULL;

-- 3) City-level daily concentration + sub-index per pollutant
CREATE OR REPLACE VIEW aqi.v_city_daily_pollutant AS
SELECT c.city_id, c.city_name, d.obs_date, d.parameter,
       ROUND(AVG(d.daily_avg), 2)                     AS concentration,
       COUNT(DISTINCT d.station_id)                   AS n_stations,
       aqi.sub_index(d.parameter, AVG(d.daily_avg))   AS sub_index
FROM aqi.v_station_daily d
JOIN aqi.stations s ON s.station_id = d.station_id
JOIN aqi.cities   c ON c.city_id    = s.city_id
GROUP BY c.city_id, c.city_name, d.obs_date, d.parameter;

-- 4) City daily AQI = worst sub-index, with dominant pollutant
CREATE OR REPLACE VIEW aqi.v_city_daily_aqi AS
SELECT city_id, city_name, obs_date,
       MAX(sub_index)                                   AS aqi,
       aqi.aqi_category(MAX(sub_index))                 AS category,
       (ARRAY_AGG(parameter ORDER BY sub_index DESC))[1] AS dominant_pollutant,
       COUNT(*)                                         AS n_pollutants,
       MAX(concentration) FILTER (WHERE parameter = 'pm25') AS pm25,
       MAX(concentration) FILTER (WHERE parameter = 'pm10') AS pm10,
       MAX(concentration) FILTER (WHERE parameter = 'no2')  AS no2,
       MAX(concentration) FILTER (WHERE parameter = 'so2')  AS so2,
       MAX(concentration) FILTER (WHERE parameter = 'co')   AS co,
       MAX(concentration) FILTER (WHERE parameter = 'o3')   AS o3
FROM aqi.v_city_daily_pollutant
GROUP BY city_id, city_name, obs_date
HAVING COUNT(*) >= 3
   AND COUNT(*) FILTER (WHERE parameter IN ('pm25','pm10')) >= 1;

-- 5) Hourly view with sub-index + category (handy for ad-hoc checks)
CREATE OR REPLACE VIEW aqi.v_hourly_enriched AS
SELECT r.*, s.station_name, c.city_name,
       aqi.sub_index(r.parameter, r.value)                      AS sub_index,
       aqi.aqi_category(aqi.sub_index(r.parameter, r.value))    AS category,
       (r.ts_utc AT TIME ZONE 'Asia/Kolkata')                   AS ts_ist
FROM aqi.readings_hourly r
JOIN aqi.stations s ON s.station_id = r.station_id
JOIN aqi.cities   c ON c.city_id    = s.city_id;
