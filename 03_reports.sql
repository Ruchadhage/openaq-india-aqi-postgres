-- =====================================================================
-- 03_reports.sql  |  Final outputs: worst days per city, monthly averages
-- =====================================================================
SET search_path = aqi, public;

-- ---------- Report 1: worst 5 days per city ---------------------------
CREATE OR REPLACE VIEW aqi.v_worst_days AS
SELECT *
FROM (
    SELECT city_name, obs_date, aqi, category, dominant_pollutant, pm25, pm10,
           RANK() OVER (PARTITION BY city_name ORDER BY aqi DESC, pm25 DESC NULLS LAST) AS rank_in_city
    FROM aqi.v_city_daily_aqi
) t
WHERE rank_in_city <= 5
ORDER BY city_name, rank_in_city;

-- ---------- Report 2: monthly averages per city ------------------------
CREATE OR REPLACE VIEW aqi.v_monthly_averages AS
SELECT city_name,
       DATE_TRUNC('month', obs_date)::date                  AS month,
       COUNT(*)                                             AS days_with_data,
       ROUND(AVG(aqi), 1)                                   AS avg_aqi,
       MAX(aqi)                                             AS max_aqi,
       ROUND(AVG(pm25), 1)                                  AS avg_pm25,
       ROUND(AVG(pm10), 1)                                  AS avg_pm10,
       ROUND(AVG(no2), 1)                                   AS avg_no2,
       COUNT(*) FILTER (WHERE aqi > 200)                    AS unhealthy_days,   -- Poor or worse
       ROUND(100.0 * COUNT(*) FILTER (WHERE aqi > 200) / COUNT(*), 1) AS pct_unhealthy_days,
       aqi.aqi_category(AVG(aqi))                           AS typical_category
FROM aqi.v_city_daily_aqi
GROUP BY city_name, DATE_TRUNC('month', obs_date)
ORDER BY city_name, month;

-- ---------- Report 3: share of unhealthy HOURS per city & pollutant ----
CREATE OR REPLACE VIEW aqi.v_unhealthy_hours AS
SELECT c.city_name, r.parameter,
       COUNT(*)                                             AS hours,
       COUNT(*) FILTER (WHERE r.is_unhealthy)               AS unhealthy_hours,
       ROUND(100.0 * COUNT(*) FILTER (WHERE r.is_unhealthy) / COUNT(*), 1) AS pct_unhealthy
FROM aqi.readings_hourly r
JOIN aqi.stations s ON s.station_id = r.station_id
JOIN aqi.cities   c ON c.city_id    = s.city_id
GROUP BY c.city_name, r.parameter
ORDER BY c.city_name, r.parameter;

-- ---------- Report 4: data-quality summary per run ---------------------
CREATE OR REPLACE VIEW aqi.v_ingest_quality AS
SELECT run_at::date AS run_date, city_name,
       SUM(rows_fetched) AS fetched, SUM(rows_invalid) AS invalid,
       SUM(rows_missing) AS missing, SUM(rows_imputed) AS imputed,
       SUM(rows_loaded)  AS loaded,
       ROUND(100.0 * SUM(rows_missing) / NULLIF(SUM(rows_loaded + rows_missing), 0), 1) AS pct_missing
FROM aqi.ingest_log
GROUP BY run_at::date, city_name
ORDER BY run_date DESC, city_name;

-- ---------- Handy queries to run manually -----------------------------
-- SELECT * FROM aqi.v_worst_days;
-- SELECT * FROM aqi.v_monthly_averages WHERE city_name = 'Delhi';
-- SELECT * FROM aqi.v_unhealthy_hours;
-- SELECT * FROM aqi.v_ingest_quality;
-- Latest AQI per city:
-- SELECT DISTINCT ON (city_name) city_name, obs_date, aqi, category
-- FROM aqi.v_city_daily_aqi ORDER BY city_name, obs_date DESC;
