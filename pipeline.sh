#!/usr/bin/env bash
# Download NOAA Storm Events details CSVs and convert them to GeoParquet with ogr2ogr.
set -euo pipefail
# -e: exit on error
# -u: error on unset variables
# -o pipefail: fail a pipeline if any command in it fails

BASE_URL="https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_DIR="${ROOT}/data/raw"
PROCESSED_DIR="${ROOT}/data/processed"
# NOAA BEGIN_LAT / BEGIN_LON are decimal degrees on WGS 84.
CRS="EPSG:4326"

usage() {
  cat <<EOF
Usage: $(basename "$0") YEAR

Download the NOAA Storm Events details CSV for YEAR, decompress it, and
convert it to GeoParquet with ogr2ogr (Point geometry from BEGIN_LON /
BEGIN_LAT, CRS ${CRS}).

Example:
  $(basename "$0") 2024
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

# Prefer an ogr2ogr build that can write GeoParquet.
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

require_cmd curl
require_cmd gzip
OGR2OGR_BIN="$(select_ogr2ogr)"

csv_path="${RAW_DIR}/StormEvents_details_d${YEAR}.csv"
parquet_path="${PROCESSED_DIR}/storm_events_${YEAR}.parquet"

# Create output directories if they don't exist
mkdir -p "${RAW_DIR}" "${PROCESSED_DIR}"

echo "Using ${OGR2OGR_BIN} ($("${OGR2OGR_BIN}" --version | head -n 1))"
echo "Fetching NOAA Storm Events file list..."
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

gz_path="${RAW_DIR}/${filename}"
if [[ -s "${gz_path}" ]]; then
  echo "Skipping download (exists): ${filename}"
else
  echo "Downloading ${filename}..."
  curl -fL --retry 3 --retry-delay 2 -o "${gz_path}.part" "${BASE_URL}/${filename}"
  mv -f "${gz_path}.part" "${gz_path}"
fi

if [[ -s "${csv_path}" ]] && [[ ! "${gz_path}" -nt "${csv_path}" ]]; then
  echo "Skipping decompress (exists): $(basename "${csv_path}")"
else
  echo "Decompressing ${filename} -> $(basename "${csv_path}")..."
  gzip -dc "${gz_path}" > "${csv_path}.part"
  mv -f "${csv_path}.part" "${csv_path}"
fi

if [[ -s "${parquet_path}" ]] && [[ ! "${csv_path}" -nt "${parquet_path}" ]]; then
  echo "Skipping convert (exists): $(basename "${parquet_path}")"
else
  echo "Converting $(basename "${csv_path}") -> $(basename "${parquet_path}") [${CRS}]..."
  tmp_path="${parquet_path}.tmp"
  rm -rf "${tmp_path}"
  "${OGR2OGR_BIN}" -f Parquet \
    -oo X_POSSIBLE_NAMES=BEGIN_LON \
    -oo Y_POSSIBLE_NAMES=BEGIN_LAT \
    -oo KEEP_GEOM_COLUMNS=YES \
    -a_srs "${CRS}" \
    -lco GEOMETRY_NAME=geometry \
    -nln storm_events \
    "${tmp_path}" \
    "${csv_path}"
  rm -rf "${parquet_path}"
  mv -f "${tmp_path}" "${parquet_path}"
fi

echo "Done. CSV:       ${csv_path}"
echo "     GeoParquet: ${parquet_path} (${CRS})"
