#!/usr/bin/env bash
#
# Run reachability scoring: start OSRM + PostGIS, fetch OI release,
# load seed data, run pike-import score, export CSV, upload to S3.
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

# ─── Start PostgreSQL + PostGIS ───────────────────────────────────
log "Starting PostgreSQL ${PG_VERSION}..."
pg_ctlcluster "$PG_VERSION" main start

su - postgres -c "psql -c \"CREATE USER ${PG_USER} WITH SUPERUSER;\"" 2>/dev/null || true
su - postgres -c "createdb -O ${PG_USER} ${PG_DB}" 2>/dev/null || true
su - postgres -c "psql -d ${PG_DB} -c 'CREATE EXTENSION IF NOT EXISTS postgis;'"
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

# ─── Create views for pike-score ──────────────────────────────────
# pike-score expects tables named exits/pois/exit_poi_candidates with
# PostGIS geometry columns. Bridge from OI's raw lat/lon schema.
log "Creating schema views for pike-score..."
psql -U "$PG_USER" -d "$PG_DB" <<SQL
CREATE VIEW exits AS
  SELECT id::text AS id,
         ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
  FROM corridor_exits;

CREATE VIEW pois AS
  SELECT id::text AS id,
         ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
  FROM places;

CREATE VIEW exit_poi_candidates AS
  SELECT exit_id::text AS exit_id,
         place_id::text AS poi_id,
         distance_m::integer AS distance_m
  FROM exit_place_links;
SQL
log "Schema views created"

# ─── Run pike-score ───────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

log "Running pike-score (${OSRM_PORT}, parallelism 16)..."
pike-score score \
  --osrm-parallelism 16 \
  --osrm-url "http://localhost:${OSRM_PORT}" \
  --database-url "postgresql://${PG_USER}@localhost/${PG_DB}"
log "Scoring complete"

# ─── Export results to CSV ─────────────────────────────────────────
# pike-score writes to the exit_poi_reachability table; export to CSV
# for the GitHub release artifact.
REACHABILITY_CSV="${OUTPUT_DIR}/reachability.csv"
log "Exporting reachability results to CSV..."
psql -U "$PG_USER" -d "$PG_DB" -c \
  "\copy (SELECT exit_id, poi_id, route_distance_m, route_duration_s, reachable, reachability_score FROM exit_poi_reachability ORDER BY exit_id, poi_id) TO '${REACHABILITY_CSV}' WITH (FORMAT csv, HEADER true)"

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
