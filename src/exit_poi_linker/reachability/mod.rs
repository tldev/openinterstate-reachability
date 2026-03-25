use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use serde::Deserialize;
use sqlx::PgPool;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

mod db;
mod osrm;
mod scoring;
mod snap;

use self::db::{
    ensure_reachability_table, ensure_snap_hint_table, fetch_pending_pairs, flush_pending_updates,
    table_exists,
};
use self::scoring::score_exit_batch;
use self::snap::prepare_snap_hints;

const DEFAULT_OSRM_URL: &str = "http://localhost:5000";
const DEFAULT_OSRM_PARALLELISM: usize = 16;
const UPDATE_BATCH_SIZE: usize = 25_000;
const SNAP_HINT_UPSERT_BATCH_SIZE: usize = 5_000;
const SNAP_HINT_PROGRESS_INTERVAL: usize = 2_000;
const SNAP_HINT_PROGRESS_MIN_INTERVAL: Duration = Duration::from_secs(15);
const SNAP_HINT_SCHEMA_VERSION: &str = "snap-product-v1";
const EXIT_NEAREST_CANDIDATE_COUNT: usize = 8;
const EXIT_SNAP_PRIMARY_RADIUS_M: f64 = 15.0;
const EXIT_SNAP_RELAXED_RADIUS_M: f64 = 25.0;
const EXIT_SNAP_PROBE_PAIR_COUNT: usize = 3;
const SNAP_AIR_DISTANCE_FLOOR_M: f64 = 50.0;
const DEFAULT_OSRM_DATASET_KEY: &str = "unspecified";
const SNAP_SCOPE_PRODUCT: &str = "product";
const SNAP_KIND_EXIT: &str = "exit";
const SNAP_KIND_POI: &str = "poi";

#[derive(Clone, Debug)]
struct PendingPair {
    exit_id: String,
    place_id: String,
    exit_lat: f64,
    exit_lon: f64,
    place_lat: f64,
    place_lon: f64,
    air_distance_m: i32,
}

#[derive(Clone, Debug)]
struct ExitBatch {
    exit_id: String,
    exit_lat: f64,
    exit_lon: f64,
    pairs: Vec<PendingPair>,
}

#[derive(Clone, Debug)]
struct UpdateRow {
    exit_id: String,
    poi_id: String,
    route_distance_m: Option<i32>,
    route_duration_s: Option<i32>,
    score: f64,
    confidence: f64,
    reachable: bool,
}

#[derive(Default)]
struct PendingUpdates {
    exit_ids: Vec<String>,
    poi_ids: Vec<String>,
    route_distance_ms: Vec<i32>,
    route_duration_ss: Vec<i32>,
    scores: Vec<f64>,
    confidences: Vec<f64>,
    reachables: Vec<bool>,
}

struct OsrmConfig {
    url: String,
    dataset_version: Option<String>,
    snap_dataset_key: String,
    parallelism: usize,
}

#[derive(Debug, Deserialize)]
struct OsrmTableResponse {
    code: String,
    distances: Option<Vec<Vec<Option<f64>>>>,
    durations: Option<Vec<Vec<Option<f64>>>>,
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OsrmNearestResponse {
    code: String,
    waypoints: Option<Vec<OsrmWaypoint>>,
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OsrmWaypoint {
    hint: Option<String>,
    location: Option<Vec<f64>>,
    distance: Option<f64>,
}

#[derive(Clone, Debug)]
struct SnapPoint {
    lon: f64,
    lat: f64,
    hint: String,
}

#[derive(Clone, Debug)]
struct SnapInputPoint {
    id: String,
    lon: f64,
    lat: f64,
}

#[derive(Debug)]
struct SnapHintRecord {
    id: String,
    input_lon: f64,
    input_lat: f64,
    snapped_lon: f64,
    snapped_lat: f64,
    hint: String,
    snapped_distance_m: Option<f64>,
}

#[derive(Clone, Debug)]
struct SnapCandidate {
    snap: SnapPoint,
    snapped_distance_m: Option<f64>,
}

/// Score reachability for all exit->POI candidate links.
pub async fn score_and_filter_poi_reachability(pool: &PgPool) -> Result<usize, anyhow::Error> {
    score_and_filter_poi_reachability_impl(pool, None).await
}

async fn score_and_filter_poi_reachability_impl(
    pool: &PgPool,
    target_exit_ids: Option<&[String]>,
) -> Result<usize, anyhow::Error> {
    ensure_required_tables(pool).await?;

    let rows = fetch_pending_pairs(pool, target_exit_ids).await?;

    if rows.is_empty() {
        tracing::info!("No pending exit->POI candidate links found for reachability scoring");
        return Ok(0);
    }

    let config = resolve_osrm_config();

    tracing::info!(
        "Reachability scoring (OSRM): pairs={} osrm_url={} parallelism={}",
        rows.len(),
        config.url,
        config.parallelism
    );

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .context("building OSRM HTTP client")?;

    let (exit_snap_hints, poi_snap_hints) = prepare_snap_hints(
        pool,
        &client,
        &config.url,
        &config.snap_dataset_key,
        &rows,
        config.parallelism,
    )
    .await?;
    let exit_snap_hints = Arc::new(exit_snap_hints);
    let poi_snap_hints = Arc::new(poi_snap_hints);

    let batches = group_rows_by_exit(rows);
    let total_exits = batches.len();
    let total_pairs: usize = batches.iter().map(|batch| batch.pairs.len()).sum();

    run_scoring_jobs(
        pool,
        &client,
        &config,
        batches,
        exit_snap_hints,
        poi_snap_hints,
        total_pairs,
    )
    .await?;

    tracing::info!(
        "Reachability scoring complete (OSRM): exits={} pairs={}",
        total_exits,
        total_pairs
    );

    Ok(0)
}

async fn ensure_required_tables(pool: &PgPool) -> Result<(), anyhow::Error> {
    ensure_reachability_table(pool).await?;
    ensure_snap_hint_table(pool).await?;

    let has_links_table = table_exists(pool, "public.exit_place_links").await?;
    let has_reachability_table = table_exists(pool, "public.exit_poi_reachability").await?;
    let has_exits_table = table_exists(pool, "public.corridor_exits").await?;
    let has_places_table = table_exists(pool, "public.places").await?;
    if !has_links_table {
        anyhow::bail!("exit_place_links table is missing");
    }
    if !has_reachability_table {
        anyhow::bail!("exit_poi_reachability table is missing");
    }
    if !has_exits_table {
        anyhow::bail!("corridor_exits table is missing");
    }
    if !has_places_table {
        anyhow::bail!("places table is missing");
    }
    Ok(())
}

fn resolve_osrm_config() -> OsrmConfig {
    let url = std::env::var("OSRM_URL").unwrap_or_else(|_| DEFAULT_OSRM_URL.to_string());
    let dataset_version = std::env::var("OSRM_DATASET_VERSION").ok();
    let dataset_key = dataset_version
        .clone()
        .unwrap_or_else(|| DEFAULT_OSRM_DATASET_KEY.to_string());
    let snap_dataset_key = format!("{dataset_key}::{SNAP_HINT_SCHEMA_VERSION}");
    let parallelism = std::env::var("OSRM_PARALLELISM")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_OSRM_PARALLELISM)
        .max(1);

    OsrmConfig {
        url,
        dataset_version,
        snap_dataset_key,
        parallelism,
    }
}

fn group_rows_by_exit(rows: Vec<PendingPair>) -> Vec<ExitBatch> {
    let mut by_exit: HashMap<String, ExitBatch> = HashMap::new();
    for row in rows {
        by_exit
            .entry(row.exit_id.clone())
            .and_modify(|batch| batch.pairs.push(row.clone()))
            .or_insert_with(|| ExitBatch {
                exit_id: row.exit_id.clone(),
                exit_lat: row.exit_lat,
                exit_lon: row.exit_lon,
                pairs: vec![row],
            });
    }
    by_exit.into_values().collect()
}

async fn run_scoring_jobs(
    pool: &PgPool,
    client: &reqwest::Client,
    config: &OsrmConfig,
    batches: Vec<ExitBatch>,
    exit_snap_hints: Arc<HashMap<String, SnapPoint>>,
    poi_snap_hints: Arc<HashMap<String, SnapPoint>>,
    total_pairs: usize,
) -> Result<(), anyhow::Error> {
    let total_exits = batches.len();
    let semaphore = Arc::new(Semaphore::new(config.parallelism));
    let mut jobs = JoinSet::new();

    for batch in batches {
        let permit = semaphore.clone().acquire_owned().await?;
        let client = client.clone();
        let osrm_url = config.url.clone();
        let exit_snap_hints = exit_snap_hints.clone();
        let poi_snap_hints = poi_snap_hints.clone();
        jobs.spawn(async move {
            let _permit = permit;
            score_exit_batch(
                &client,
                &osrm_url,
                batch,
                exit_snap_hints.as_ref(),
                poi_snap_hints.as_ref(),
            )
            .await
        });
    }

    let mut pending = PendingUpdates::default();
    let mut processed_exits = 0usize;
    let mut processed_pairs = 0usize;

    while let Some(result) = jobs.join_next().await {
        let updates = result.context("join error while scoring reachability")??;
        processed_exits += 1;
        processed_pairs += updates.len();

        for update in updates {
            pending.exit_ids.push(update.exit_id);
            pending.poi_ids.push(update.poi_id);
            pending
                .route_distance_ms
                .push(update.route_distance_m.unwrap_or(-1));
            pending
                .route_duration_ss
                .push(update.route_duration_s.unwrap_or(-1));
            pending.scores.push(update.score);
            pending.confidences.push(update.confidence);
            pending.reachables.push(update.reachable);
        }

        if pending.exit_ids.len() >= UPDATE_BATCH_SIZE {
            flush_pending_updates(pool, &mut pending, config.dataset_version.as_deref()).await?;
        }

        if processed_exits % 250 == 0 || processed_exits == total_exits {
            tracing::info!(
                "Reachability scoring progress: exits={}/{} pairs={}/{}",
                processed_exits,
                total_exits,
                processed_pairs,
                total_pairs
            );
        }
    }

    flush_pending_updates(pool, &mut pending, config.dataset_version.as_deref()).await?;
    Ok(())
}
