#!/usr/bin/env bash
#
# Download US PBF, filter with osmium, and build OSRM dataset.
# Attaches EBS volume, runs the build, then detaches on exit.
#
set -euo pipefail

SCRIPT_NAME="osm-build"
OSRM_DIR="/mnt/osrm"
OSRM_PROFILES="${OSRM_PROFILES:-/opt/osrm-profiles}"
PBF_URL="https://download.geofabrik.de/north-america/us-latest.osm.pbf"
S3_BUCKET="${S3_BUCKET:-}"
REGION="${AWS_REGION:-us-east-1}"
S3_PBF_KEY="us-latest.osm.pbf"
EBS_VOLUME_ID="${EBS_VOLUME_ID:?EBS_VOLUME_ID must be set}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[${SCRIPT_NAME}][$(date -u +%FT%TZ)] $*"; }

cleanup() {
  log "Cleaning up..."
  bash "${SCRIPTS_DIR}/unmount-ebs.sh" "$EBS_VOLUME_ID" "$OSRM_DIR" || true
}
trap cleanup EXIT

log "Starting osm-build pipeline"

# ─── Attach and mount EBS volume ─────────────────────────────────
bash "${SCRIPTS_DIR}/mount-ebs.sh" "$EBS_VOLUME_ID" "$OSRM_DIR"

WORK_DIR="${OSRM_DIR}/work"
MARKER_DIR="${OSRM_DIR}/markers"
log "OSRM output directory: ${OSRM_DIR}"
mkdir -p "$WORK_DIR" "$MARKER_DIR"

# ─── Download PBF ─────────────────────────────────────────────────
PBF_FILE="${WORK_DIR}/us-latest.osm.pbf"
if [[ -f "${MARKER_DIR}/.download-complete" ]]; then
  log "PBF download already completed, skipping"
elif [[ -f "$PBF_FILE" ]]; then
  log "PBF file exists but no completion marker — re-downloading"
  rm -f "$PBF_FILE"
fi

if [[ ! -f "${MARKER_DIR}/.download-complete" ]]; then
  S3_PBF_PATH="s3://${S3_BUCKET}/${S3_PBF_KEY}"
  if [[ -n "$S3_BUCKET" ]] && aws s3 ls "$S3_PBF_PATH" --region "$REGION" >/dev/null 2>&1; then
    log "Downloading US PBF from S3 (${S3_PBF_PATH})..."
    aws s3 cp "$S3_PBF_PATH" "$PBF_FILE" --region "$REGION"
  else
    log "Downloading US PBF from Geofabrik (~11 GB)..."
    wget -O "$PBF_FILE" "$PBF_URL"
  fi
  touch "${MARKER_DIR}/.download-complete"
  log "Download complete: $(du -h "$PBF_FILE" | cut -f1)"
fi

# ─── Filter with osmium ──────────────────────────────────────────
FILTERED_FILE="${WORK_DIR}/us-filtered.osm.pbf"
if [[ -f "${MARKER_DIR}/.filter-complete" ]]; then
  log "Osmium filter already completed, skipping"
else
  log "Filtering PBF with osmium (full road network + OI-canonical POIs)..."
  rm -f "$FILTERED_FILE"
  osmium tags-filter "$PBF_FILE" \
    w/highway=motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link,residential,unclassified,service,living_street,rest_area \
    n/amenity=fuel,restaurant,fast_food,cafe,charging_station \
    n/tourism=hotel,motel \
    n/shop=gas \
    n/cuisine \
    n/highway=rest_area \
    w/amenity=fuel,restaurant,fast_food,cafe,charging_station \
    w/tourism=hotel,motel \
    w/shop=gas \
    w/cuisine \
    w/highway=rest_area \
    -o "$FILTERED_FILE" \
    --overwrite
  touch "${MARKER_DIR}/.filter-complete"
  log "Filter complete: $(du -h "$FILTERED_FILE" | cut -f1)"

  # Free disk space — unfiltered PBF no longer needed
  log "Removing unfiltered PBF to free disk space (~11 GB)"
  rm -f "$PBF_FILE"
  rm -f "${MARKER_DIR}/.download-complete"
fi

# ─── OSRM Extract ────────────────────────────────────────────────
OSRM_BASE="${WORK_DIR}/us-filtered"
if [[ -f "${MARKER_DIR}/.extract-complete" ]]; then
  log "OSRM extract already completed, skipping"
else
  log "Running osrm-extract (MLD profile)..."
  osrm-extract \
    -p "${OSRM_PROFILES}/car.lua" \
    "$FILTERED_FILE"
  touch "${MARKER_DIR}/.extract-complete"
  log "Extract complete"
fi

# ─── OSRM Partition ──────────────────────────────────────────────
if [[ -f "${MARKER_DIR}/.partition-complete" ]]; then
  log "OSRM partition already completed, skipping"
else
  log "Running osrm-partition..."
  osrm-partition "${OSRM_BASE}.osrm"
  touch "${MARKER_DIR}/.partition-complete"
  log "Partition complete"
fi

# ─── OSRM Customize ──────────────────────────────────────────────
if [[ -f "${MARKER_DIR}/.customize-complete" ]]; then
  log "OSRM customize already completed, skipping"
else
  log "Running osrm-customize..."
  osrm-customize "${OSRM_BASE}.osrm"
  touch "${MARKER_DIR}/.customize-complete"
  log "Customize complete"
fi

# ─── Write completion marker ─────────────────────────────────────
log "Writing completion marker"
cat > "${OSRM_DIR}/.osm-build-complete" <<MARKER
osm_build_completed=$(date -u +%FT%TZ)
osrm_base=${OSRM_BASE}
pbf_source=${PBF_URL}
MARKER

log "osm-build pipeline complete"
log "OSRM dataset at: ${OSRM_BASE}.osrm"
ls -lh "${WORK_DIR}/"
