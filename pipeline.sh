#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pipeline.sh — NOAA Storm Events details → GeoParquet
#
# Downloads only the details CSV for one year (not locations or fatalities),
# decompresses it, and converts it with ogr2ogr.
#
# Usage:  ./pipeline.sh YEAR
# Example: ./pipeline.sh 2024
# -----------------------------------------------------------------------------
set -euo pipefail
# -e: exit on error
# -u: error on unset variables
# -o pipefail: fail a pipeline if any command in it fails

# NOAA bulk CSV directory (HTTPS, despite the historical "ftp" in filenames)
BASE_URL="https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_DIR="${ROOT}/data/raw"
PROCESSED_DIR="${ROOT}/data/processed"
# NOAA BEGIN_LAT / BEGIN_LON are decimal degrees on WGS 84
CRS="EPSG:4326"

usage() {
  cat <<EOF
Usage: $(basename "$0") YEAR

Download only the NOAA Storm Events details file for YEAR (not locations
or fatalities), decompress it, and convert it to GeoParquet with ogr2ogr
(Point geometry from BEGIN_LON / BEGIN_LAT, CRS ${CRS}).

Example:
  $(basename "$0") 2024
EOF
}

# Exit if a required command is missing from PATH.
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

# Some GDAL builds (e.g. MacPorts) have no Parquet driver. Prefer Homebrew,
# then PATH, then MacPorts. Override with OGR2OGR=/path/to/ogr2ogr.
select_ogr2ogr() {
  local candidate
  for candidate in \
      "${OGR2OGR:-}" \
      /opt/homebrew/bin/ogr2ogr \
      /usr/local/bin/ogr2ogr \
      "$(command -v ogr2ogr || true)" \
      /opt/local/bin/ogr2ogr
  do
    if [[ -n "${candidate}" && -x "${candidate}" ]] \
        && "${candidate}" --formats 2>/dev/null | grep -q 'Parquet'; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  echo "error: ogr2ogr with Parquet support not found (try: brew install gdal)" >&2
  exit 1
}

# --- 1. Check the year argument ----------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

YEAR="$1"
if [[ ! "${YEAR}" =~ ^[0-9]{4}$ ]]; then
  echo "error: YEAR must be a 4-digit year, got: ${YEAR}" >&2
  exit 1
fi

# --- 2. Check tools ----------------------------------------------------------
require_cmd curl
require_cmd gzip
OGR2OGR_BIN="$(select_ogr2ogr)"

csv_path="${RAW_DIR}/StormEvents_details_d${YEAR}.csv"
parquet_path="${PROCESSED_DIR}/storm_events_${YEAR}.parquet"

# --- 3. Create output directories if they don't exist ------------------------
mkdir -p "${RAW_DIR}" "${PROCESSED_DIR}"

echo "Using ${OGR2OGR_BIN} ($("${OGR2OGR_BIN}" --version | head -n 1))"

# --- 4. Find the latest details file for YEAR --------------------------------
# Filenames look like: StormEvents_details-ftp_v1.0_d2024_c20260728.csv.gz
# dYYYY = data year, cYYYYMMDD = NOAA creation date (newest wins).
echo "Fetching NOAA Storm Events details file list..."
listing="$(curl -fsSL "${BASE_URL}/")"
filename="$(
  printf '%s\n' "${listing}" \
    | grep -oE "StormEvents_details-ftp_v[0-9.]+_d${YEAR}_c[0-9]+\.csv\.gz" \
    | sort \
    | tail -n 1 \
    || true
)"

if [[ -z "${filename}" ]]; then
  echo "error: no Storm Events details file found for ${YEAR} at ${BASE_URL}" >&2
  exit 1
fi

# --- 5. Download the .csv.gz (skip if already present) -----------------------
# Write to .part then rename so a failed download is not treated as complete.
gz_path="${RAW_DIR}/${filename}"
if [[ -s "${gz_path}" ]]; then
  echo "Skipping download (exists): ${filename}"
else
  echo "Downloading ${filename}..."
  curl -fL --retry 3 --retry-delay 2 -o "${gz_path}.part" "${BASE_URL}/${filename}"
  mv -f "${gz_path}.part" "${gz_path}"
fi

# --- 6. Decompress to a plain CSV (skip if up to date) -----------------------
# gzip -dc keeps the original .gz. Re-run if NOAA replaced the archive.
if [[ -s "${csv_path}" ]] && [[ ! "${gz_path}" -nt "${csv_path}" ]]; then
  echo "Skipping decompress (exists): $(basename "${csv_path}")"
else
  echo "Decompressing ${filename} -> $(basename "${csv_path}")..."
  gzip -dc "${gz_path}" > "${csv_path}.part"
  mv -f "${csv_path}.part" "${csv_path}"
fi

# --- 7. Convert CSV → GeoParquet with ogr2ogr (skip if up to date) -----------
if [[ -s "${parquet_path}" ]] && [[ ! "${csv_path}" -nt "${parquet_path}" ]]; then
  echo "Skipping convert (exists): $(basename "${parquet_path}")"
else
  echo "Converting $(basename "${csv_path}") -> $(basename "${parquet_path}") [${CRS}]..."
  tmp_path="${parquet_path}.tmp"
  rm -rf "${tmp_path}"
  # X_POSSIBLE_NAMES / Y_POSSIBLE_NAMES — Point from lon/lat
  # KEEP_GEOM_COLUMNS=YES               — keep BEGIN_LON / BEGIN_LAT as attributes
  # -a_srs EPSG:4326                    — assign WGS 84 (do not reproject)
  # GEOMETRY_NAME=geometry              — GeoParquet geometry column name
  # -nln storm_events                   — layer name inside the parquet file
  "${OGR2OGR_BIN}" -f Parquet \
    -oo X_POSSIBLE_NAMES=BEGIN_LON \
    -oo Y_POSSIBLE_NAMES=BEGIN_LAT \
    -oo KEEP_GEOM_COLUMNS=YES \
    -a_srs "${CRS}" \
    -lco GEOMETRY_NAME=geometry \
    -nln storm_events \
    "${tmp_path}" \
    "${csv_path}"
  # Replace the output only after ogr2ogr succeeds.
  rm -rf "${parquet_path}"
  mv -f "${tmp_path}" "${parquet_path}"
fi

echo "Done. CSV:       ${csv_path}"
echo "     GeoParquet: ${parquet_path} (${CRS})"
