# noaa-storms-pipeline

Downloads NOAA Storm Events bulk files for a given year, keeps the original gzipped CSVs, and converts them to GeoParquet.

Source files come from the [NCEI Storm Events bulk CSV directory](https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles/). For each year the script fetches the latest **details**, **locations**, and **fatalities** files.

Coordinates are NOAA decimal-degree lat/lon, stored as WGS 84 (**EPSG:4326**). Each GeoParquet file has a `geometry` column:

- **details** — point from `BEGIN_LON` / `BEGIN_LAT` (falls back to end coordinates)
- **locations** — point from `LONGITUDE` / `LATITUDE`
- **fatalities** — point from the matching details event (`EVENT_ID`)

The script is safe to rerun: it creates `data/raw` and `data/processed` with `mkdir -p`, skips downloads that already exist, and skips GeoParquet files that are already up to date.

## Requirements

- bash
- [curl](https://curl.se/)
- [DuckDB](https://duckdb.org/) (`brew install duckdb` on macOS)

## Usage

```bash
chmod +x pipeline.sh
./pipeline.sh 2024
```

## Layout

```
noaa-storms-pipeline/
├── pipeline.sh          # the main script
├── README.md
├── .gitignore           # excludes data/ from git
├── LICENSE
└── data/                # created by pipeline.sh, not committed
    ├── raw/             # downloaded .csv.gz files
    └── processed/       # GeoParquet files (EPSG:4326)
```

After a run you should see files such as:

- `data/raw/StormEvents_details-ftp_v1.0_d2024_cYYYYMMDD.csv.gz`
- `data/processed/StormEvents_details_2024.parquet`
- `data/processed/StormEvents_locations_2024.parquet`
- `data/processed/StormEvents_fatalities_2024.parquet`
