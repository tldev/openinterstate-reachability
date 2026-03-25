#!/usr/bin/env bash
#
# Download US PBF, filter with osmium, and build OSRM dataset.
# Runs inside the Batch container with /mnt/osrm mounted.
#
set -euo pipefail

OSRM_DIR="/mnt/osrm"
OSRM_PROFILES="${OSRM_PROFILES:-/opt/osrm-profiles}"
PBF_URL="https://download.geofabrik.de/north-america/us-latest.osm.pbf"
WORK_DIR="${OSRM_DIR}/work"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

log "Starting osm-build pipeline"
log "OSRM output directory: ${OSRM_DIR}"
mkdir -p "$WORK_DIR"

# ─── Download PBF ─────────────────────────────────────────────────
PBF_FILE="${WORK_DIR}/us-latest.osm.pbf"
if [[ -f "$PBF_FILE" ]]; then
  log "PBF file already exists, skipping download"
else
  log "Downloading US PBF from Geofabrik (~11 GB)..."
  wget -q --show-progress -O "$PBF_FILE" "$PBF_URL"
  log "Download complete: $(du -h "$PBF_FILE" | cut -f1)"
fi

# ─── Filter with osmium ──────────────────────────────────────────
FILTERED_FILE="${WORK_DIR}/us-filtered.osm.pbf"
if [[ -f "$FILTERED_FILE" ]]; then
  log "Filtered PBF already exists, skipping filter"
else
  log "Filtering PBF with osmium (highways + POI amenities)..."
  osmium tags-filter "$PBF_FILE" \
    w/highway=motorway,motorway_link,trunk,trunk_link,primary,secondary \
    n/amenity=fuel,restaurant,fast_food,cafe,food_court \
    n/amenity=hotel,motel \
    n/tourism=hotel,motel \
    n/shop=convenience \
    -o "$FILTERED_FILE" \
    --overwrite
  log "Filter complete: $(du -h "$FILTERED_FILE" | cut -f1)"
fi

# ─── OSRM Extract ────────────────────────────────────────────────
OSRM_BASE="${WORK_DIR}/us-filtered"
if [[ -f "${OSRM_BASE}.osrm" ]]; then
  log "OSRM extract output already exists, skipping"
else
  log "Running osrm-extract (MLD profile)..."
  osrm-extract \
    -p "${OSRM_PROFILES}/car.lua" \
    "$FILTERED_FILE"
  log "Extract complete"
fi

# ─── OSRM Partition ──────────────────────────────────────────────
if [[ -f "${OSRM_BASE}.osrm.partition" ]]; then
  log "OSRM partition output already exists, skipping"
else
  log "Running osrm-partition..."
  osrm-partition "${OSRM_BASE}.osrm"
  log "Partition complete"
fi

# ─── OSRM Customize ──────────────────────────────────────────────
if [[ -f "${OSRM_BASE}.osrm.cell_metrics" ]]; then
  log "OSRM customize output already exists, skipping"
else
  log "Running osrm-customize..."
  osrm-customize "${OSRM_BASE}.osrm"
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
