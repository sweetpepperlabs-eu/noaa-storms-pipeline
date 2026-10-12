#!/usr/bin/env bash
# Download NOAA Storm Events bulk CSVs for a year and convert them to GeoParquet.
set -euo pipefail
# -e: exit on error
# -u: error on unset variables
# -o pipefail: fail a pipeline if any command in it fails

BASE_URL="https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_DIR="${ROOT}/data/raw"
PROCESSED_DIR="${ROOT}/data/processed"
TABLES=(details locations fatalities)
# NOAA lat/lon are decimal degrees on WGS 84.
CRS="EPSG:4326"

usage() {
  cat <<EOF
Usage: $(basename "$0") YEAR

Download NOAA Storm Events files for YEAR, save the gzipped CSVs under
data/raw/, and write GeoParquet files (CRS ${CRS}) to data/processed/.

Safe to rerun: existing directories and files are reused.

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

has_geo_metadata() {
  local count
  count="$(
    duckdb -csv -noheader -c "SELECT COUNT(*) FROM parquet_kv_metadata('$1') WHERE CAST(key AS VARCHAR) = 'geo';" \
      | tail -n 1 \
      | tr -d '[:space:]'
  )"
  [[ "${count}" == "1" ]]
}

sql_point() {
  local lon_col="$1"
  local lat_col="$2"
  cat <<EOF
ST_SetCRS(
  CASE
    WHEN TRY_CAST(NULLIF(TRIM(${lon_col}), '') AS DOUBLE) IS NOT NULL
     AND TRY_CAST(NULLIF(TRIM(${lat_col}), '') AS DOUBLE) IS NOT NULL
    THEN ST_Point(
      TRY_CAST(NULLIF(TRIM(${lon_col}), '') AS DOUBLE),
      TRY_CAST(NULLIF(TRIM(${lat_col}), '') AS DOUBLE)
    )
    ELSE NULL
  END,
  '${CRS}'
)
EOF
}

geometry_select_sql() {
  local table="$1"
  local raw_path="$2"
  local csv_opts="header=true, all_varchar=true, ignore_errors=true"
  case "${table}" in
    details)
      cat <<EOF
SELECT
  src.*,
  ST_SetCRS(
    CASE
      WHEN TRY_CAST(NULLIF(TRIM(BEGIN_LON), '') AS DOUBLE) IS NOT NULL
       AND TRY_CAST(NULLIF(TRIM(BEGIN_LAT), '') AS DOUBLE) IS NOT NULL
      THEN ST_Point(
        TRY_CAST(NULLIF(TRIM(BEGIN_LON), '') AS DOUBLE),
        TRY_CAST(NULLIF(TRIM(BEGIN_LAT), '') AS DOUBLE)
      )
      WHEN TRY_CAST(NULLIF(TRIM(END_LON), '') AS DOUBLE) IS NOT NULL
       AND TRY_CAST(NULLIF(TRIM(END_LAT), '') AS DOUBLE) IS NOT NULL
      THEN ST_Point(
        TRY_CAST(NULLIF(TRIM(END_LON), '') AS DOUBLE),
        TRY_CAST(NULLIF(TRIM(END_LAT), '') AS DOUBLE)
      )
      ELSE NULL
    END,
    '${CRS}'
  ) AS geometry
FROM read_csv('${raw_path}', ${csv_opts}) AS src
EOF
      ;;
    locations)
      cat <<EOF
SELECT
  src.*,
  $(sql_point LONGITUDE LATITUDE) AS geometry
FROM read_csv('${raw_path}', ${csv_opts}) AS src
EOF
      ;;
    fatalities)
      if [[ -n "${DETAILS_RAW:-}" && -s "${DETAILS_RAW}" ]]; then
        cat <<EOF
SELECT
  f.*,
  $(sql_point 'd.BEGIN_LON' 'd.BEGIN_LAT') AS geometry
FROM read_csv('${raw_path}', ${csv_opts}) AS f
LEFT JOIN read_csv('${DETAILS_RAW}', ${csv_opts}) AS d
  ON f.EVENT_ID = d.EVENT_ID
EOF
      else
        cat <<EOF
SELECT
  src.*,
  ST_SetCRS(ST_GeomFromText('POINT EMPTY'), '${CRS}') AS geometry
FROM read_csv('${raw_path}', ${csv_opts}) AS src
EOF
      fi
      ;;
    *)
      echo "error: unknown table ${table}" >&2
      exit 1
      ;;
  esac
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
if [[ ! "$YEAR" =~ ^[0-9]{4}$ ]]; then
  echo "error: YEAR must be a 4-digit year, got: ${YEAR}" >&2
  exit 1
fi

require_cmd curl
require_cmd duckdb

# Create output directories if they don't exist
mkdir -p "${RAW_DIR}" "${PROCESSED_DIR}"

echo "Fetching NOAA Storm Events file list..."
listing="$(curl -fsSL "${BASE_URL}/")"
matches="$(
  printf '%s\n' "${listing}" \
    | grep -oE "StormEvents_(details|locations|fatalities)-ftp_v[0-9.]+_d${YEAR}_c[0-9]+\.csv\.gz" \
    | sort -u \
    || true
)"

if [[ -z "${matches}" ]]; then
  echo "error: no Storm Events files found for ${YEAR} at ${BASE_URL}" >&2
  exit 1
fi

downloaded=()
DETAILS_RAW=""
for table in "${TABLES[@]}"; do
  filename="$(
    printf '%s\n' "${matches}" \
      | grep -E "^StormEvents_${table}-ftp_" \
      | sort \
      | tail -n 1 \
      || true
  )"
  if [[ -z "${filename}" ]]; then
    echo "warning: no ${table} file for ${YEAR}; skipping" >&2
    continue
  fi

  raw_path="${RAW_DIR}/${filename}"
  if [[ -s "${raw_path}" ]]; then
    echo "Skipping download (exists): ${filename}"
  else
    echo "Downloading ${filename}..."
    curl -fL --retry 3 --retry-delay 2 -o "${raw_path}.part" "${BASE_URL}/${filename}"
    mv -f "${raw_path}.part" "${raw_path}"
  fi
  downloaded+=("${raw_path}")
  if [[ "${table}" == "details" ]]; then
    DETAILS_RAW="${raw_path}"
  fi
done

if [[ ${#downloaded[@]} -eq 0 ]]; then
  echo "error: nothing downloaded for ${YEAR}" >&2
  exit 1
fi

for raw_path in "${downloaded[@]}"; do
  filename="$(basename "${raw_path}")"
  table="$(sed -E 's/^StormEvents_([a-z]+)-ftp_.*/\1/' <<<"${filename}")"
  parquet_path="${PROCESSED_DIR}/StormEvents_${table}_${YEAR}.parquet"

  if [[ -s "${parquet_path}" ]] \
      && [[ ! "${raw_path}" -nt "${parquet_path}" ]] \
      && has_geo_metadata "${parquet_path}"; then
    echo "Skipping convert (exists): $(basename "${parquet_path}")"
    continue
  fi

  echo "Converting ${filename} -> $(basename "${parquet_path}") [${CRS}]..."
  tmp_path="${parquet_path}.tmp"
  rm -f "${tmp_path}"
  duckdb -c "
    INSTALL spatial;
    LOAD spatial;
    COPY (
      $(geometry_select_sql "${table}" "${raw_path}")
    ) TO '${tmp_path}' (FORMAT PARQUET, COMPRESSION ZSTD);
  "
  mv -f "${tmp_path}" "${parquet_path}"
done

echo "Done. Raw files: ${RAW_DIR}"
echo "     GeoParquet (${CRS}): ${PROCESSED_DIR}"
