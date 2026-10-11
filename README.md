# 🌫️ India Air Quality (AQI) Collector

An end-to-end data pipeline that pulls **hourly air-quality readings for Indian cities** from the free [OpenAQ](https://openaq.org) API, cleans them in **Python**, stores them in **PostgreSQL**, and uses **SQL** to compute daily AQI (India's CPCB method), the **worst days per city** and **monthly averages**.

> **Stack:** Python (pandas, requests, psycopg2, matplotlib) · Jupyter Notebook (Anaconda) · PostgreSQL + pgAdmin 4 · SQL (views, window functions, CTEs)

---

## Results

Worst day per city and Monthly average AQI in docs


*Example from a short test run (Delhi + Mumbai, ~48 h of data). Only Mumbai qualifies for a daily AQI so far; coverage grows as you collect more history.*

---

## How it works

```
OpenAQ API v3 ──► Jupyter notebook (Python) ──► PostgreSQL (aqi schema) ──► SQL views ──► reports / charts
   hourly           clean · convert · flag         upsert, idempotent         daily AQI        worst days
   per sensor       (missing values, units)                                   (CPCB method)    monthly averages
```

1. **Extract** – for each city, find monitoring stations within 25 km, skip stations that stopped reporting, and pull hourly values for each pollutant sensor (pagination, rate-limit handling and retries included).
2. **Transform (Python)**
   - **Missing values:** nulls, sentinel values (`-999`…), negatives and physically impossible readings → treated as missing; gaps of ≤ 3 h are linearly interpolated and flagged `is_imputed`; longer gaps are left empty (never invented).
   - **Unit conversion:** ppb / ppm / mg/m³ → µg/m³ (CO → mg/m³) at 25 °C, 1 atm.
   - **Unhealthy flag:** an hourly reading in the CPCB *Poor* band or worse is flagged `is_unhealthy` (PM2.5 > 90, PM10 > 250, NO₂ > 180, SO₂ > 380 µg/m³, CO > 10 mg/m³, O₃ > 168 µg/m³).
3. **Load** – upsert into PostgreSQL (`ON CONFLICT DO UPDATE`), so re-running or overlapping windows never creates duplicates. Every run is recorded in an audit table.
4. **Analyse (SQL)** – views compute daily AQI per city and the two final outputs.

### AQI method (CPCB National AQI)
- PM2.5, PM10, NO₂, SO₂ → 24-hour average; CO, O₃ → maximum rolling 8-hour average.
- A pollutant-day needs ≥ 16 valid hours; a city-day needs ≥ 3 pollutants, one of them PM2.5 or PM10.
- Sub-index per pollutant via linear interpolation of the CPCB breakpoints; **city AQI = worst sub-index**, with the dominant pollutant reported.
- Categories: Good (0–50) · Satisfactory (51–100) · Moderate (101–200) · Poor (201–300) · Very Poor (301–400) · Severe (401+).
- Days are Indian Standard Time (Asia/Kolkata) calendar days.

---

### Database objects (schema `aqi`)
| Object | Type | Purpose |
|---|---|---|
| `cities`, `stations` | tables | city list (editable) and OpenAQ monitoring stations |
| `readings_hourly` | table | cleaned hourly readings; PK `(station_id, parameter, ts_utc)` |
| `ingest_log` | table | per-run, per-city data-quality counts (fetched / invalid / missing / imputed / loaded) |
| `breakpoints` | table | CPCB AQI breakpoints |
| `sub_index()`, `aqi_category()` | functions | AQI maths in SQL |
| `v_station_daily`, `v_city_daily_pollutant`, `v_city_daily_aqi` | views | daily aggregation and city AQI |
| **`v_worst_days`** | view | **5 worst days per city** (`RANK() OVER (PARTITION BY city …)`) |
| **`v_monthly_averages`** | view | **monthly avg/max AQI, PM2.5, PM10, NO₂, unhealthy-day counts** |
| `v_unhealthy_hours`, `v_ingest_quality` | views | share of unhealthy hours; data-quality monitoring |

---

## Getting started

### Prerequisites
- [Anaconda](https://www.anaconda.com/download) (Python 3 + Jupyter)
- [PostgreSQL](https://www.postgresql.org/download/) with pgAdmin 4
- A free OpenAQ API key: <https://explore.openaq.org/register>

### 1. Create the database
In pgAdmin: create a database named **`aqi_db`**, open a Query Tool on it and run, in order:
`sql/01_schema.sql` → `sql/02_views.sql` → `sql/03_reports.sql`

### 2. Install dependencies
```bash
pip install -r requirements.txt
```

### 3. Configure credentials (environment variables – never commit secrets)
```bash
# Windows (Anaconda Prompt)
set PGPASSWORD=your_postgres_password
set OPENAQ_API_KEY=your_openaq_key

# macOS / Linux
export PGPASSWORD=your_postgres_password
export OPENAQ_API_KEY=your_openaq_key
```
Optional: `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER` (defaults: `localhost`, `5432`, `aqi_db`, `postgres`).

### 4. Run
```bash
jupyter notebook
```
Open `notebooks/aqi_collector.ipynb` → **Kernel → Restart & Run All**.

### Configuration (first cell of the notebook)
| Setting | Default | Meaning |
|---|---|---|
| `CITIES_TO_RUN` | `["Delhi", "Mumbai"]` | start small; set to `None` for all cities in `aqi.cities` |
| `LOOKBACK_HOURS` | `48` | hours of history per run; raise (e.g. `24*30`) for a backfill |
| `MAX_STATIONS_PER_CITY` | `3` | fewer stations = fewer API calls |
| `MAX_STALE_DAYS` | `7` | ignore stations whose newest reading is older than this |
| `MAX_GAP_HOURS` | `3` | longest gap that is interpolated |

---

## Example queries
```sql
-- 5 worst days for every city
SELECT * FROM aqi.v_worst_days;

-- Monthly averages for one city
SELECT * FROM aqi.v_monthly_averages WHERE city_name = 'Mumbai';

-- Which pollutants are unhealthy most often?
SELECT * FROM aqi.v_unhealthy_hours ORDER BY pct_unhealthy DESC;

-- Latest AQI per city
SELECT DISTINCT ON (city_name) city_name, obs_date, aqi, category
FROM aqi.v_city_daily_aqi ORDER BY city_name, obs_date DESC;
```

## Collecting hourly snapshots
Each run upserts the last `LOOKBACK_HOURS` hours, so running it on a schedule builds a continuous hourly history and automatically back-fills any missed run:
```bash
jupyter nbconvert --to notebook --execute notebooks/aqi_collector.ipynb --output-dir runs
```
Schedule it hourly with Windows Task Scheduler or `cron` (`0 * * * *`).

---


## Data sources & credits
- Air-quality data: [OpenAQ](https://openaq.org) (aggregated from government and research monitors, e.g. CPCB).
- AQI breakpoints: India Central Pollution Control Board (CPCB) National Air Quality Index.


