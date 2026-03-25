#!/usr/bin/env bash
#
# Run reachability scoring: start OSRM + PostGIS, fetch OI release,
# load seed data, run pike-import score, export CSV, upload to S3.
# Runs inside the Batch container with /mnt/osrm mounted.
#
set -euo pipefail

SCRIPT_NAME="score"
OSRM_DIR="/mnt/osrm"
PIPELINE_RUN_ID="${PIPELINE_RUN_ID:?PIPELINE_RUN_ID must be set}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET must be set}"
OI_REPO="${OI_REPO:-tldev/openinterstate}"
OSRM_PORT="${OSRM_PORT:-5000}"
PG_DB="pike_scoring"
PG_USER="pike"
OUTPUT_DIR="/tmp/reachability-output"
REGION="${AWS_REGION:-us-east-1}"
PG_VERSION=$(pg_lsclusters -h 2>/dev/null | awk '{print $1}' | head -1)
PG_VERSION="${PG_VERSION:-15}"

log() { echo "[${SCRIPT_NAME}][$(date -u +%FT%TZ)] $*"; }

cleanup() {
  log "Cleaning up..."
  if [[ -n "${OSRM_PID:-}" ]] && kill -0 "$OSRM_PID" 2>/dev/null; then
    kill "$OSRM_PID" || true
    wait "$OSRM_PID" 2>/dev/null || true
  fi
  pg_ctlcluster "$PG_VERSION" main stop 2>/dev/null || true
}
trap cleanup EXIT

log "Starting scoring pipeline"

# ─── Verify OSRM data ────────────────────────────────────────────
if [[ ! -f "${OSRM_DIR}/.osm-build-complete" ]]; then
  log "ERROR: ${OSRM_DIR}/.osm-build-complete not found. osm-build must run first." >&2
  exit 1
fi

OSRM_BASE=$(grep '^osrm_base=' "${OSRM_DIR}/.osm-build-complete" | cut -d= -f2)
if [[ -z "$OSRM_BASE" || ! -f "${OSRM_BASE}.osrm" ]]; then
  log "ERROR: OSRM dataset not found at ${OSRM_BASE}" >&2
  exit 1
fi
log "OSRM dataset: ${OSRM_BASE}"

# ─── Start OSRM ──────────────────────────────────────────────────
log "Starting osrm-routed on port ${OSRM_PORT}..."
osrm-routed \
  --algorithm mld \
  --port "$OSRM_PORT" \
  --max-table-size 10000 \
  "${OSRM_BASE}.osrm" &
OSRM_PID=$!

log "Waiting for OSRM to start..."
OSRM_READY=false
for i in $(seq 1 60); do
  if curl -sf "http://localhost:${OSRM_PORT}/route/v1/driving/-73.9857,40.7484;-73.9857,40.7484" >/dev/null 2>&1; then
    log "OSRM is ready (attempt ${i})"
    OSRM_READY=true
    break
  fi
  if ! kill -0 "$OSRM_PID" 2>/dev/null; then
    log "ERROR: OSRM process died" >&2
    exit 1
  fi
  sleep 5
done

if [[ "$OSRM_READY" != "true" ]]; then
  log "ERROR: OSRM failed to start within 300 seconds" >&2
  exit 1
fi

# ─── Start PostgreSQL + PostGIS ───────────────────────────────────
log "Starting PostgreSQL ${PG_VERSION}..."
pg_ctlcluster "$PG_VERSION" main start

su - postgres -c "psql -c \"CREATE USER ${PG_USER} WITH SUPERUSER;\"" 2>/dev/null || true
su - postgres -c "createdb -O ${PG_USER} ${PG_DB}" 2>/dev/null || true
su - postgres -c "psql -d ${PG_DB} -c 'CREATE EXTENSION IF NOT EXISTS postgis;'"
log "PostgreSQL ready with database ${PG_DB}"

# ─── Fetch OpenInterstate release ────────────────────────────────
OI_DIR="/tmp/openinterstate"
OI_DATA_DIR="${OI_DIR}/data"
mkdir -p "$OI_DIR" "$OI_DATA_DIR"

log "Fetching latest OpenInterstate release from ${OI_REPO}..."
gh release download \
  --repo "$OI_REPO" \
  --pattern '*.tar.gz' \
  --dir "$OI_DIR" \
  --clobber

# Validate exactly one tarball
TARBALL_COUNT=$(find "$OI_DIR" -maxdepth 1 -name '*.tar.gz' | wc -l)
if [[ "$TARBALL_COUNT" -ne 1 ]]; then
  log "ERROR: Expected 1 tarball, found ${TARBALL_COUNT}" >&2
  ls -la "$OI_DIR/" >&2
  exit 1
fi

TARBALL=$(find "$OI_DIR" -maxdepth 1 -name '*.tar.gz' -print -quit)
log "Extracting ${TARBALL} to ${OI_DATA_DIR}..."
tar xzf "$TARBALL" -C "$OI_DATA_DIR" --strip-components=1 2>/dev/null \
  || tar xzf "$TARBALL" -C "$OI_DATA_DIR"

# Locate CSVs explicitly
find_csv() {
  local name="$1"
  local csv
  csv=$(find "$OI_DATA_DIR" -name "$name" -print -quit)
  if [[ -z "$csv" ]]; then
    log "ERROR: ${name} not found in OI release" >&2
    exit 1
  fi
  echo "$csv"
}

EXITS_CSV=$(find_csv "corridor_exits.csv")
PLACES_CSV=$(find_csv "places.csv")
LINKS_CSV=$(find_csv "exit_place_links.csv")
log "Found CSVs: $(basename "$EXITS_CSV"), $(basename "$PLACES_CSV"), $(basename "$LINKS_CSV")"

# ─── Load OI data into PostGIS ────────────────────────────────────
log "Loading OI data into PostGIS..."

psql -U "$PG_USER" -d "$PG_DB" <<SQL
CREATE TABLE IF NOT EXISTS corridor_exits (
  id INTEGER PRIMARY KEY,
  corridor_id INTEGER,
  exit_number TEXT,
  name TEXT,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  sequence INTEGER
);

CREATE TABLE IF NOT EXISTS places (
  id INTEGER PRIMARY KEY,
  name TEXT,
  category TEXT,
  subcategory TEXT,
  latitude DOUBLE PRECISION,
  longitude DOUBLE PRECISION,
  osm_id BIGINT
);

CREATE TABLE IF NOT EXISTS exit_place_links (
  exit_id INTEGER,
  place_id INTEGER,
  distance_m DOUBLE PRECISION
);

\copy corridor_exits FROM '${EXITS_CSV}' WITH (FORMAT csv, HEADER true)
\copy places FROM '${PLACES_CSV}' WITH (FORMAT csv, HEADER true)
\copy exit_place_links FROM '${LINKS_CSV}' WITH (FORMAT csv, HEADER true)
SQL

EXIT_COUNT=$(psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM corridor_exits")
PLACE_COUNT=$(psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM places")
LINK_COUNT=$(psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM exit_place_links")
log "Loaded: ${EXIT_COUNT} exits, ${PLACE_COUNT} places, ${LINK_COUNT} exit-place links"

# ─── Run pike-import score ────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

log "Running pike-import score (16 parallel connections)..."
pike-import score \
  --parallel 16 \
  --osrm-url "http://localhost:${OSRM_PORT}" \
  --database-url "postgresql://${PG_USER}@localhost/${PG_DB}" \
  --output-dir "$OUTPUT_DIR"
log "Scoring complete"

# ─── Verify output ───────────────────────────────────────────────
REACHABILITY_CSV="${OUTPUT_DIR}/reachability.csv"
if [[ ! -f "$REACHABILITY_CSV" ]]; then
  log "ERROR: reachability.csv not found in ${OUTPUT_DIR}" >&2
  ls -la "$OUTPUT_DIR/" >&2
  exit 1
fi

# Validate CSV schema
EXPECTED_HEADER="exit_id,poi_id,route_distance_m,route_duration_s,reachable,reachability_score"
ACTUAL_HEADER=$(head -1 "$REACHABILITY_CSV")
if [[ "$ACTUAL_HEADER" != "$EXPECTED_HEADER" ]]; then
  log "ERROR: Unexpected CSV schema" >&2
  log "Expected: ${EXPECTED_HEADER}" >&2
  log "Got:      ${ACTUAL_HEADER}" >&2
  exit 1
fi

ROW_COUNT=$(tail -n +2 "$REACHABILITY_CSV" | wc -l)
FILE_SIZE=$(du -h "$REACHABILITY_CSV" | cut -f1)
log "Output: reachability.csv — ${ROW_COUNT} data rows, ${FILE_SIZE}"

# ─── Upload to S3 ────────────────────────────────────────────────
S3_PREFIX="s3://${S3_BUCKET}/${PIPELINE_RUN_ID}"
log "Uploading output to ${S3_PREFIX}/"

aws s3 cp "$REACHABILITY_CSV" "${S3_PREFIX}/reachability.csv" --region "$REGION"

SNAP_HINTS="${OUTPUT_DIR}/osrm_snap_hints.csv"
if [[ -f "$SNAP_HINTS" ]]; then
  aws s3 cp "$SNAP_HINTS" "${S3_PREFIX}/osrm_snap_hints.csv" --region "$REGION"
  log "Uploaded osrm_snap_hints.csv"
fi

log "Upload complete"
log "Scoring pipeline finished successfully"
