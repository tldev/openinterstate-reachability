#!/usr/bin/env bash
#
# Run reachability scoring: start OSRM + PostgreSQL, fetch OI release,
# load seed data, run pike-score, export CSV, upload to S3.
# Attaches EBS volume (OSRM data from osm-build), detaches on exit.
#
set -euo pipefail

SCRIPT_NAME="score"
OSRM_DIR="/mnt/osrm"
PIPELINE_RUN_ID="${PIPELINE_RUN_ID:?PIPELINE_RUN_ID must be set}"
S3_BUCKET="${S3_BUCKET:?S3_BUCKET must be set}"
EBS_VOLUME_ID="${EBS_VOLUME_ID:?EBS_VOLUME_ID must be set}"
OI_RELEASE_TAG="${OI_RELEASE_TAG:-}"
OSRM_PORT="${OSRM_PORT:-5000}"
PG_DB="pike_scoring"
PG_USER="pike"
OUTPUT_DIR="/tmp/reachability-output"
REGION="${AWS_REGION:-us-east-1}"
PG_VERSION=$(pg_lsclusters -h 2>/dev/null | awk '{print $1}' | head -1)
PG_VERSION="${PG_VERSION:-15}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[${SCRIPT_NAME}][$(date -u +%FT%TZ)] $*"; }

cleanup() {
  log "Cleaning up..."
  if [[ -n "${OSRM_PID:-}" ]] && kill -0 "$OSRM_PID" 2>/dev/null; then
    kill "$OSRM_PID" || true
    wait "$OSRM_PID" 2>/dev/null || true
  fi
  pg_ctlcluster "$PG_VERSION" main stop 2>/dev/null || true
  bash "${SCRIPTS_DIR}/unmount-ebs.sh" "$EBS_VOLUME_ID" "$OSRM_DIR" || true
}
trap cleanup EXIT

log "Starting scoring pipeline"

# ─── Attach and mount EBS volume ─────────────────────────────────
bash "${SCRIPTS_DIR}/mount-ebs.sh" "$EBS_VOLUME_ID" "$OSRM_DIR"

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

# ─── Start PostgreSQL ────────────────────────────────────────────
log "Starting PostgreSQL ${PG_VERSION}..."
pg_ctlcluster "$PG_VERSION" main start

su - postgres -c "psql -c \"CREATE USER ${PG_USER} WITH SUPERUSER;\"" 2>/dev/null || true
su - postgres -c "createdb -O ${PG_USER} ${PG_DB}" 2>/dev/null || true
log "PostgreSQL ready with database ${PG_DB}"

# ─── Fetch OpenInterstate release from S3 ──────────────────────────
# The GHA workflow downloads the OI release (which requires GitHub auth
# for private repos) and stages it to S3. The container pulls from S3.
OI_DIR="/tmp/openinterstate"
OI_DATA_DIR="${OI_DIR}/data"
mkdir -p "$OI_DIR" "$OI_DATA_DIR"

S3_OI_PREFIX="s3://${S3_BUCKET}/${PIPELINE_RUN_ID}/oi-release"
log "Downloading OI release from ${S3_OI_PREFIX}/ (tag: ${OI_RELEASE_TAG:-unset})..."
aws s3 cp "${S3_OI_PREFIX}/" "$OI_DIR/" \
  --recursive \
  --region "$REGION"

# Validate exactly one tarball
TARBALL_COUNT=$(find "$OI_DIR" -maxdepth 1 -name '*.tar.gz' | wc -l)
if [[ "$TARBALL_COUNT" -ne 1 ]]; then
  log "ERROR: Expected 1 tarball in S3, found ${TARBALL_COUNT}" >&2
  ls -la "$OI_DIR/" >&2
  exit 1
fi

TARBALL=$(find "$OI_DIR" -maxdepth 1 -name '*.tar.gz' -print -quit)
log "Extracting $(basename "$TARBALL") to ${OI_DATA_DIR}..."
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

# ─── Load OI data into PostgreSQL ─────────────────────────────────
log "Loading OI data into PostgreSQL..."

psql -U "$PG_USER" -d "$PG_DB" <<SQL
CREATE TABLE IF NOT EXISTS corridor_exits (
  exit_id TEXT PRIMARY KEY,
  corridor_id INTEGER,
  interstate_name TEXT,
  direction_code TEXT,
  sequence_index INTEGER,
  exit_number TEXT,
  exit_name TEXT,
  lat DOUBLE PRECISION,
  lon DOUBLE PRECISION,
  geometry_geojson TEXT
);

CREATE TABLE IF NOT EXISTS places (
  place_id TEXT PRIMARY KEY,
  category TEXT,
  name TEXT,
  display_name TEXT,
  brand TEXT,
  geometry_geojson TEXT
);

CREATE TABLE IF NOT EXISTS exit_place_links (
  exit_id TEXT,
  place_id TEXT,
  category TEXT,
  distance_m INTEGER,
  rank INTEGER
);

\copy corridor_exits FROM '${EXITS_CSV}' WITH (FORMAT csv, HEADER true)
\copy places FROM '${PLACES_CSV}' WITH (FORMAT csv, HEADER true)
\copy exit_place_links FROM '${LINKS_CSV}' WITH (FORMAT csv, HEADER true)
SQL

# Extract lat/lon from geometry_geojson for places (GeoJSON has no lat/lon columns)
log "Extracting lat/lon from places geometry_geojson..."
psql -U "$PG_USER" -d "$PG_DB" <<SQL
ALTER TABLE places ADD COLUMN lat DOUBLE PRECISION;
ALTER TABLE places ADD COLUMN lon DOUBLE PRECISION;
UPDATE places SET
  lon = (geometry_geojson::json->'coordinates'->>0)::double precision,
  lat = (geometry_geojson::json->'coordinates'->>1)::double precision
WHERE geometry_geojson IS NOT NULL;
SQL

EXIT_COUNT=$(psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM corridor_exits")
PLACE_COUNT=$(psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM places")
LINK_COUNT=$(psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM exit_place_links")
log "Loaded: ${EXIT_COUNT} exits, ${PLACE_COUNT} places, ${LINK_COUNT} exit-place links"

# ─── Run pike-score ───────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

log "Running pike-score (${OSRM_PORT}, parallelism 16)..."
pike-score score \
  --osrm-parallelism 16 \
  --osrm-url "http://localhost:${OSRM_PORT}" \
  --database-url "postgresql://${PG_USER}@localhost/${PG_DB}"
log "Scoring complete"

# ─── Export results to CSV ─────────────────────────────────────────
# pike-score writes to the exit_place_scores table; export to CSV
# for the GitHub release artifact.
REACHABILITY_CSV="${OUTPUT_DIR}/reachability.csv"
log "Exporting reachability results to CSV..."
psql -U "$PG_USER" -d "$PG_DB" -c \
  "\copy (SELECT exit_id, place_id, route_distance_m, route_duration_s, reachable, reachability_score, reachability_confidence, provider, provider_dataset_version, updated_at FROM exit_place_scores ORDER BY exit_id, place_id) TO '${REACHABILITY_CSV}' WITH (FORMAT csv, HEADER true)"

if [[ ! -f "$REACHABILITY_CSV" ]]; then
  log "ERROR: CSV export failed — reachability.csv not created" >&2
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
