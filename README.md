# noaa-storms-pipeline

Downloads the NOAA Storm Events **details** CSV for a given year, decompresses it, and converts it to GeoParquet with `ogr2ogr`.

Source files come from the [NCEI Storm Events bulk CSV directory](https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles/), for example `StormEvents_details-ftp_v1.0_d2024_c20260728.csv.gz`.

`ogr2ogr` builds Point geometries from `BEGIN_LON` / `BEGIN_LAT` and assigns **EPSG:4326** (WGS 84).

The script is safe to rerun: it creates `data/raw` and `data/processed` with `mkdir -p` and skips work when outputs already exist.

## Requirements

- bash
- [curl](https://curl.se/)
- gzip
- [GDAL](https://gdal.org/) with Parquet support (`ogr2ogr --version` to check; `brew install gdal` on macOS)

## Usage

```bash
./pipeline.sh 2024
```

## Layout

```
noaa-storms-pipeline/
├── pipeline.sh
├── README.md
├── .gitignore           # excludes data/ from git
├── LICENSE
└── data/                # created by pipeline.sh, not committed
    ├── raw/             # downloaded .csv.gz and decompressed CSV
    └── processed/       # GeoParquet (EPSG:4326)
```

After a run you should see files such as:

- `data/raw/StormEvents_details-ftp_v1.0_d2024_cYYYYMMDD.csv.gz`
- `data/raw/StormEvents_details_d2024.csv`
- `data/processed/storm_events_2024.parquet`
