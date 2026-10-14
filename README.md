# noaa-storms-pipeline

`pipeline.sh` downloads **one** NOAA Storm Events **details** file for a year, decompresses it, and converts it to GeoParquet with `ogr2ogr`.

It does **not** download locations or fatalities files.

Source: [NCEI Storm Events bulk CSV directory](https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles/). Example:

`StormEvents_details-ftp_v1.0_d2024_c20260728.csv.gz`

Coordinates come from `BEGIN_LON` / `BEGIN_LAT` and are stored as Point geometries in **EPSG:4326** (WGS 84).

## Requirements

- bash
- [curl](https://curl.se/)
- gzip
- [GDAL](https://gdal.org/) with **Parquet** support (`brew install gdal` on macOS)
- internet access

Check GDAL:

```bash
ogr2ogr --version
```

If more than one GDAL is installed, the script prefers a build that can write Parquet (Homebrew GDAL on this machine). You can also set `OGR2OGR` to a specific binary.

## Usage

```bash
chmod +x pipeline.sh
./pipeline.sh 2024
```

```bash
./pipeline.sh --help
```

The year must be four digits. NOAA currently publishes details files from 1950 through the current year.

## What the script does

The script uses `set -euo pipefail` so it stops on errors, unset variables, and failed pipelines.

1. **Check the year**  
   Requires a single argument, `YEAR`.

2. **Check tools**  
   Requires `curl` and `gzip`, then selects an `ogr2ogr` that supports Parquet.

3. **Create directories**  
   `mkdir -p data/raw data/processed` (no-op if they already exist).

4. **Find the details file**  
   Lists the NOAA directory and picks the latest details archive for that year:

   `StormEvents_details-ftp_v1.0_dYYYY_cYYYYMMDD.csv.gz`

   The `cYYYYMMDD` part is NOAA’s file-creation date. If NOAA republishes the year, the newest date wins.

5. **Download**  
   Saves the `.csv.gz` to `data/raw/`. Skips the download if that file already exists.

6. **Decompress**  
   Writes a plain CSV:

   `data/raw/StormEvents_details_dYYYY.csv`

   Skips this step if the CSV already exists and is not older than the `.gz`.

7. **Convert with ogr2ogr**  
   Builds GeoParquet:

   `data/processed/storm_events_YYYY.parquet`

   `ogr2ogr` uses:

   - `BEGIN_LON` as X and `BEGIN_LAT` as Y
   - Point geometry, CRS **EPSG:4326**
   - layer name `storm_events`
   - geometry column `geometry`
   - original CSV columns kept (`KEEP_GEOM_COLUMNS=YES`)

   Rows without lat/lon are kept, with an empty geometry.

   Conversion writes a temp file first, then replaces the output, so a failed run does not leave a half-written parquet.

8. **Skip work on rerun**  
   Existing directories and up-to-date files are reused. Running `./pipeline.sh 2024` again should skip download, decompress, and convert.

## Layout

```
noaa-storms-pipeline/
├── pipeline.sh          # the main script
├── README.md
├── .gitignore           # excludes data/ from git
├── LICENSE
└── data/                # created by pipeline.sh, not committed
    ├── raw/
    │   ├── StormEvents_details-ftp_v1.0_dYYYY_cYYYYMMDD.csv.gz
    │   └── StormEvents_details_dYYYY.csv
    └── processed/
        └── storm_events_YYYY.parquet
```

After `./pipeline.sh 2024` you should see:

- `data/raw/StormEvents_details-ftp_v1.0_d2024_c20260728.csv.gz`
- `data/raw/StormEvents_details_d2024.csv`
- `data/processed/storm_events_2024.parquet`

## Inspect the GeoParquet

```bash
ogrinfo -so data/processed/storm_events_2024.parquet
```

You should see layer `storm_events`, geometry type Point, and SRS `EPSG:4326`.

## What I learned

1. I learned to run small pipeline using shell commands.
2. Fine tuning the instruction until I reach the goal.
3. I learned a couple of commands from GDAL. 
