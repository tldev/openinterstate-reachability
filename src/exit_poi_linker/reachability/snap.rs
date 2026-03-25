use super::*;
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

use super::osrm::{fetch_nearest_snap, resolve_exit_snap_candidate};

type ExitSnapSelection = Option<(SnapPoint, Option<f64>, bool)>;
type ExitSnapJoinOutput = (SnapInputPoint, ExitSnapSelection);

struct ExitSnapProgress {
    processed: usize,
    total: usize,
    queued: usize,
    inflight: usize,
    cached_new: usize,
    failed: usize,
    disambiguated: usize,
}

pub(super) async fn prepare_snap_hints(
    pool: &PgPool,
    client: &reqwest::Client,
    osrm_url: &str,
    dataset_key: &str,
    rows: &[PendingPair],
    parallelism: usize,
) -> Result<(HashMap<String, SnapPoint>, HashMap<String, SnapPoint>), anyhow::Error> {
    let mut unique_exits: HashMap<String, (f64, f64)> = HashMap::new();
    let mut unique_pois: HashMap<String, (f64, f64)> = HashMap::new();
    let mut pairs_by_exit: HashMap<String, Vec<PendingPair>> = HashMap::new();

    for pair in rows {
        unique_exits
            .entry(pair.exit_id.clone())
            .or_insert((pair.exit_lon, pair.exit_lat));
        unique_pois
            .entry(pair.poi_id.clone())
            .or_insert((pair.poi_lon, pair.poi_lat));
        pairs_by_exit
            .entry(pair.exit_id.clone())
            .or_default()
            .push(pair.clone());
    }

    for pairs in pairs_by_exit.values_mut() {
        pairs.sort_by_key(|p| p.air_distance_m);
    }

    let context = SnapHintContext {
        pool,
        client,
        osrm_url,
        source_scope: SNAP_SCOPE_PRODUCT,
        dataset_key,
        parallelism,
    };

    let poi_hints = prepare_snap_hints_for_kind(&context, SNAP_KIND_POI, &unique_pois, 1).await?;
    let exit_hints = prepare_exit_snap_hints(&context, &unique_exits, &pairs_by_exit).await?;

    Ok((exit_hints, poi_hints))
}

struct SnapHintContext<'a> {
    pool: &'a PgPool,
    client: &'a reqwest::Client,
    osrm_url: &'a str,
    source_scope: &'a str,
    dataset_key: &'a str,
    parallelism: usize,
}

async fn prepare_snap_hints_for_kind(
    context: &SnapHintContext<'_>,
    endpoint_kind: &str,
    input_points: &HashMap<String, (f64, f64)>,
    nearest_number: usize,
) -> Result<HashMap<String, SnapPoint>, anyhow::Error> {
    let SnapHintContext {
        pool,
        client,
        osrm_url,
        source_scope,
        dataset_key,
        parallelism,
    } = context;

    if input_points.is_empty() {
        return Ok(HashMap::new());
    }

    let mut cached =
        load_snap_hints(pool, source_scope, endpoint_kind, dataset_key, input_points).await?;
    let mut missing = Vec::new();

    for (id, (lon, lat)) in input_points {
        if !cached.contains_key(id) {
            missing.push(SnapInputPoint {
                id: id.clone(),
                lon: *lon,
                lat: *lat,
            });
        }
    }

    tracing::info!(
        "OSRM snap hints: scope={} kind={} dataset_key={} cached={} missing={}",
        source_scope,
        endpoint_kind,
        dataset_key,
        cached.len(),
        missing.len()
    );

    if missing.is_empty() {
        return Ok(cached);
    }

    let (fresh, records, failed) =
        snap_missing_points(client, osrm_url, &missing, *parallelism, nearest_number).await;
    if !records.is_empty() {
        upsert_snap_hints(
            pool,
            source_scope,
            endpoint_kind,
            dataset_key,
            records.as_slice(),
        )
        .await?;
    }

    cached.extend(fresh);

    tracing::info!(
        "OSRM snap hints ready: scope={} kind={} dataset_key={} total={} failed={}",
        source_scope,
        endpoint_kind,
        dataset_key,
        cached.len(),
        failed
    );

    Ok(cached)
}

async fn prepare_exit_snap_hints(
    context: &SnapHintContext<'_>,
    input_points: &HashMap<String, (f64, f64)>,
    pairs_by_exit: &HashMap<String, Vec<PendingPair>>,
) -> Result<HashMap<String, SnapPoint>, anyhow::Error> {
    let SnapHintContext {
        pool,
        client,
        osrm_url,
        source_scope,
        dataset_key,
        parallelism,
    } = context;

    if input_points.is_empty() {
        return Ok(HashMap::new());
    }

    let mut cached = load_snap_hints(
        pool,
        source_scope,
        SNAP_KIND_EXIT,
        dataset_key,
        input_points,
    )
    .await?;
    let mut missing = Vec::new();

    for (id, (lon, lat)) in input_points {
        if !cached.contains_key(id) {
            missing.push(SnapInputPoint {
                id: id.clone(),
                lon: *lon,
                lat: *lat,
            });
        }
    }

    tracing::info!(
        "OSRM snap hints: scope={} kind={} dataset_key={} cached={} missing={}",
        source_scope,
        SNAP_KIND_EXIT,
        dataset_key,
        cached.len(),
        missing.len()
    );

    if missing.is_empty() {
        return Ok(cached);
    }

    let (fresh, records, failed, disambiguated) =
        snap_missing_exits(client, osrm_url, &missing, pairs_by_exit, *parallelism).await;
    if !records.is_empty() {
        upsert_snap_hints(
            pool,
            source_scope,
            SNAP_KIND_EXIT,
            dataset_key,
            records.as_slice(),
        )
        .await?;
    }

    cached.extend(fresh);

    tracing::info!(
        "OSRM snap hints ready: scope={} kind={} dataset_key={} total={} failed={} disambiguated={}",
        source_scope,
        SNAP_KIND_EXIT,
        dataset_key,
        cached.len(),
        failed,
        disambiguated
    );

    Ok(cached)
}

async fn load_snap_hints(
    pool: &PgPool,
    source_scope: &str,
    endpoint_kind: &str,
    dataset_key: &str,
    input_points: &HashMap<String, (f64, f64)>,
) -> Result<HashMap<String, SnapPoint>, anyhow::Error> {
    let ids: Vec<String> = input_points.keys().cloned().collect();
    let mut out = HashMap::new();

    for chunk in ids.chunks(SNAP_HINT_UPSERT_BATCH_SIZE) {
        let chunk_ids: Vec<String> = chunk.to_vec();
        let rows: Vec<(String, f64, f64, String)> = sqlx::query_as(
            "SELECT endpoint_id, snapped_lon, snapped_lat, hint \
             FROM osrm_snap_hints \
             WHERE source_scope = $1 \
               AND endpoint_kind = $2 \
               AND dataset_key = $3 \
               AND endpoint_id = ANY($4)",
        )
        .bind(source_scope)
        .bind(endpoint_kind)
        .bind(dataset_key)
        .bind(&chunk_ids)
        .fetch_all(pool)
        .await?;

        for (id, lon, lat, hint) in rows {
            out.insert(id, SnapPoint { lon, lat, hint });
        }
    }

    Ok(out)
}

async fn snap_missing_points(
    client: &reqwest::Client,
    osrm_url: &str,
    input_points: &[SnapInputPoint],
    parallelism: usize,
    nearest_number: usize,
) -> (HashMap<String, SnapPoint>, Vec<SnapHintRecord>, usize) {
    let mut jobs = JoinSet::new();
    let semaphore = Arc::new(Semaphore::new(parallelism.max(1)));
    let nearest_number = nearest_number.max(1);

    let mut results = HashMap::new();
    let mut records = Vec::new();
    let mut failed = 0usize;
    let mut processed = 0usize;
    let total = input_points.len();
    let mut queued = 0usize;
    let mut last_log = Instant::now();
    let started = Instant::now();

    while queued < total && jobs.len() < parallelism.max(1) {
        let permit = match semaphore.clone().acquire_owned().await {
            Ok(v) => v,
            Err(_) => break,
        };
        let client = client.clone();
        let osrm_url = osrm_url.to_string();
        let input = input_points[queued].clone();
        jobs.spawn(async move {
            let _permit = permit;
            let snap = fetch_nearest_snap(&client, &osrm_url, &input, nearest_number).await;
            (input, snap)
        });
        queued += 1;
    }

    while let Some(joined) = jobs.join_next().await {
        match joined {
            Ok((input, maybe_snap)) => {
                processed += 1;
                if let Some((snap, snap_distance_m)) = maybe_snap {
                    records.push(SnapHintRecord {
                        id: input.id.clone(),
                        input_lon: input.lon,
                        input_lat: input.lat,
                        snapped_lon: snap.lon,
                        snapped_lat: snap.lat,
                        hint: snap.hint.clone(),
                        snapped_distance_m: snap_distance_m,
                    });
                    results.insert(input.id, snap);
                } else {
                    failed += 1;
                }
            }
            Err(err) => {
                processed += 1;
                failed += 1;
                tracing::warn!("OSRM snap hint join error: {}", err);
            }
        }

        while queued < total && jobs.len() < parallelism.max(1) {
            let permit = match semaphore.clone().acquire_owned().await {
                Ok(v) => v,
                Err(_) => break,
            };
            let client = client.clone();
            let osrm_url = osrm_url.to_string();
            let input = input_points[queued].clone();
            jobs.spawn(async move {
                let _permit = permit;
                let snap = fetch_nearest_snap(&client, &osrm_url, &input, nearest_number).await;
                (input, snap)
            });
            queued += 1;
        }

        let since_last = last_log.elapsed();
        if processed % SNAP_HINT_PROGRESS_INTERVAL == 0
            || processed == total
            || since_last >= SNAP_HINT_PROGRESS_MIN_INTERVAL
        {
            let elapsed_s = started.elapsed().as_secs_f64().max(0.001);
            let rate = processed as f64 / elapsed_s;
            let remaining = total.saturating_sub(processed);
            let eta_s = if rate > 0.0 {
                (remaining as f64 / rate).round() as i64
            } else {
                -1
            };
            tracing::info!(
                "OSRM snap warmup progress: points={}/{} queued={} inflight={} cached_new={} failed={} rate={:.1}/s eta_s={}",
                processed,
                total,
                queued,
                jobs.len(),
                results.len(),
                failed,
                rate,
                eta_s
            );
            last_log = Instant::now();
        }
    }

    (results, records, failed)
}

async fn snap_missing_exits(
    client: &reqwest::Client,
    osrm_url: &str,
    input_points: &[SnapInputPoint],
    pairs_by_exit: &HashMap<String, Vec<PendingPair>>,
    parallelism: usize,
) -> (
    HashMap<String, SnapPoint>,
    Vec<SnapHintRecord>,
    usize,
    usize,
) {
    let mut jobs = JoinSet::new();
    let semaphore = Arc::new(Semaphore::new(parallelism.max(1)));

    let mut results = HashMap::new();
    let mut records = Vec::new();
    let mut failed = 0usize;
    let mut processed = 0usize;
    let mut disambiguated = 0usize;
    let total = input_points.len();
    let mut queued = 0usize;
    let mut last_log = Instant::now();
    let started = Instant::now();

    while queued < total && jobs.len() < parallelism.max(1) {
        if !enqueue_exit_snap_job(
            &mut jobs,
            &semaphore,
            client,
            osrm_url,
            input_points[queued].clone(),
            pairs_by_exit,
        )
        .await
        {
            break;
        }
        queued += 1;
    }

    while let Some(joined) = jobs.join_next().await {
        process_exit_snap_join_result(
            joined,
            &mut results,
            &mut records,
            &mut failed,
            &mut processed,
            &mut disambiguated,
        );

        while queued < total && jobs.len() < parallelism.max(1) {
            if !enqueue_exit_snap_job(
                &mut jobs,
                &semaphore,
                client,
                osrm_url,
                input_points[queued].clone(),
                pairs_by_exit,
            )
            .await
            {
                break;
            }
            queued += 1;
        }

        maybe_log_exit_snap_progress(
            &ExitSnapProgress {
                processed,
                total,
                queued,
                inflight: jobs.len(),
                cached_new: results.len(),
                failed,
                disambiguated,
            },
            &started,
            &mut last_log,
        );
    }

    (results, records, failed, disambiguated)
}

async fn enqueue_exit_snap_job(
    jobs: &mut JoinSet<ExitSnapJoinOutput>,
    semaphore: &Arc<Semaphore>,
    client: &reqwest::Client,
    osrm_url: &str,
    input: SnapInputPoint,
    pairs_by_exit: &HashMap<String, Vec<PendingPair>>,
) -> bool {
    let permit = match semaphore.clone().acquire_owned().await {
        Ok(value) => value,
        Err(_) => return false,
    };
    let client = client.clone();
    let osrm_url = osrm_url.to_string();
    let pairs = pairs_by_exit
        .get(&input.id)
        .cloned()
        .unwrap_or_else(Vec::new);
    jobs.spawn(async move {
        let _permit = permit;
        let selected = resolve_exit_snap_candidate(&client, &osrm_url, &input, &pairs).await;
        (input, selected)
    });
    true
}

fn process_exit_snap_join_result(
    joined: Result<ExitSnapJoinOutput, tokio::task::JoinError>,
    results: &mut HashMap<String, SnapPoint>,
    records: &mut Vec<SnapHintRecord>,
    failed: &mut usize,
    processed: &mut usize,
    disambiguated: &mut usize,
) {
    match joined {
        Ok((input, maybe_selected)) => {
            *processed += 1;
            if let Some((snap, snap_distance_m, was_disambiguated)) = maybe_selected {
                if was_disambiguated {
                    *disambiguated += 1;
                }
                records.push(SnapHintRecord {
                    id: input.id.clone(),
                    input_lon: input.lon,
                    input_lat: input.lat,
                    snapped_lon: snap.lon,
                    snapped_lat: snap.lat,
                    hint: snap.hint.clone(),
                    snapped_distance_m: snap_distance_m,
                });
                results.insert(input.id, snap);
            } else {
                *failed += 1;
            }
        }
        Err(err) => {
            *processed += 1;
            *failed += 1;
            tracing::warn!("OSRM exit snap hint join error: {}", err);
        }
    }
}

fn maybe_log_exit_snap_progress(
    progress: &ExitSnapProgress,
    started: &Instant,
    last_log: &mut Instant,
) {
    let since_last = last_log.elapsed();
    if progress.processed % SNAP_HINT_PROGRESS_INTERVAL != 0
        && progress.processed != progress.total
        && since_last < SNAP_HINT_PROGRESS_MIN_INTERVAL
    {
        return;
    }

    let elapsed_s = started.elapsed().as_secs_f64().max(0.001);
    let rate = progress.processed as f64 / elapsed_s;
    let remaining = progress.total.saturating_sub(progress.processed);
    let eta_s = if rate > 0.0 {
        (remaining as f64 / rate).round() as i64
    } else {
        -1
    };
    tracing::info!(
        "OSRM exit snap warmup progress: points={}/{} queued={} inflight={} cached_new={} failed={} disambiguated={} rate={:.1}/s eta_s={}",
        progress.processed,
        progress.total,
        progress.queued,
        progress.inflight,
        progress.cached_new,
        progress.failed,
        progress.disambiguated,
        rate,
        eta_s
    );
    *last_log = Instant::now();
}

async fn upsert_snap_hints(
    pool: &PgPool,
    source_scope: &str,
    endpoint_kind: &str,
    dataset_key: &str,
    records: &[SnapHintRecord],
) -> Result<(), anyhow::Error> {
    if records.is_empty() {
        return Ok(());
    }

    for chunk in records.chunks(SNAP_HINT_UPSERT_BATCH_SIZE) {
        let mut ids = Vec::with_capacity(chunk.len());
        let mut input_lons = Vec::with_capacity(chunk.len());
        let mut input_lats = Vec::with_capacity(chunk.len());
        let mut snapped_lons = Vec::with_capacity(chunk.len());
        let mut snapped_lats = Vec::with_capacity(chunk.len());
        let mut hints = Vec::with_capacity(chunk.len());
        let mut snapped_distances = Vec::with_capacity(chunk.len());

        for row in chunk {
            ids.push(row.id.clone());
            input_lons.push(row.input_lon);
            input_lats.push(row.input_lat);
            snapped_lons.push(row.snapped_lon);
            snapped_lats.push(row.snapped_lat);
            hints.push(row.hint.clone());
            snapped_distances.push(row.snapped_distance_m);
        }

        sqlx::query(
            "INSERT INTO osrm_snap_hints \
             (source_scope, endpoint_kind, endpoint_id, dataset_key, \
              input_lon, input_lat, snapped_lon, snapped_lat, hint, snapped_distance_m, updated_at) \
             SELECT \
                $1, \
                $2, \
                u.endpoint_id, \
                $3, \
                u.input_lon, \
                u.input_lat, \
                u.snapped_lon, \
                u.snapped_lat, \
                u.hint, \
                u.snapped_distance_m, \
                NOW() \
             FROM ( \
                SELECT \
                    UNNEST($4::text[]) AS endpoint_id, \
                    UNNEST($5::double precision[]) AS input_lon, \
                    UNNEST($6::double precision[]) AS input_lat, \
                    UNNEST($7::double precision[]) AS snapped_lon, \
                    UNNEST($8::double precision[]) AS snapped_lat, \
                    UNNEST($9::text[]) AS hint, \
                    UNNEST($10::double precision[]) AS snapped_distance_m \
             ) u \
             ON CONFLICT (source_scope, endpoint_kind, endpoint_id, dataset_key) DO UPDATE \
             SET input_lon = EXCLUDED.input_lon, \
                 input_lat = EXCLUDED.input_lat, \
                 snapped_lon = EXCLUDED.snapped_lon, \
                 snapped_lat = EXCLUDED.snapped_lat, \
                 hint = EXCLUDED.hint, \
                 snapped_distance_m = EXCLUDED.snapped_distance_m, \
                 updated_at = NOW()",
        )
        .bind(source_scope)
        .bind(endpoint_kind)
        .bind(dataset_key)
        .bind(&ids)
        .bind(&input_lons)
        .bind(&input_lats)
        .bind(&snapped_lons)
        .bind(&snapped_lats)
        .bind(&hints)
        .bind(&snapped_distances)
        .execute(pool)
        .await?;
    }

    Ok(())
}
