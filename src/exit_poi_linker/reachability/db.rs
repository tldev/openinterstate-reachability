use super::*;

pub(super) async fn table_exists(pool: &PgPool, regclass: &str) -> Result<bool, anyhow::Error> {
    let (exists,): (bool,) = sqlx::query_as("SELECT to_regclass($1) IS NOT NULL")
        .bind(regclass)
        .fetch_one(pool)
        .await?;
    Ok(exists)
}

pub(super) async fn fetch_pending_pairs(
    pool: &PgPool,
    target_exit_ids: Option<&[String]>,
) -> Result<Vec<PendingPair>, anyhow::Error> {
    let qrows: Vec<(String, String, f64, f64, f64, f64, f64)> = match target_exit_ids {
        Some(ids) => {
            sqlx::query_as(
                "SELECT DISTINCT c.exit_id, c.place_id, \
                        e.lat, e.lon, \
                        p.lat, p.lon, \
                        c.distance_m \
                 FROM exit_place_links c \
                 JOIN corridor_exits e ON e.exit_id = c.exit_id \
                 JOIN places p ON p.place_id = c.place_id \
                 LEFT JOIN exit_place_scores r \
                   ON r.exit_id = c.exit_id AND r.place_id = c.place_id \
                 WHERE c.exit_id = ANY($1) \
                   AND (r.exit_id IS NULL OR r.reachability_score IS NULL OR r.reachability_confidence IS NULL)",
            )
            .bind(ids)
            .fetch_all(pool)
            .await?
        }
        None => {
            sqlx::query_as(
                "SELECT DISTINCT c.exit_id, c.place_id, \
                        e.lat, e.lon, \
                        p.lat, p.lon, \
                        c.distance_m \
                 FROM exit_place_links c \
                 JOIN corridor_exits e ON e.exit_id = c.exit_id \
                 JOIN places p ON p.place_id = c.place_id \
                 LEFT JOIN exit_place_scores r \
                   ON r.exit_id = c.exit_id AND r.place_id = c.place_id \
                 WHERE r.exit_id IS NULL OR r.reachability_score IS NULL OR r.reachability_confidence IS NULL",
            )
            .fetch_all(pool)
            .await?
        }
    };

    Ok(qrows
        .into_iter()
        .map(|r| PendingPair {
            exit_id: r.0,
            place_id: r.1,
            exit_lat: r.2,
            exit_lon: r.3,
            place_lat: r.4,
            place_lon: r.5,
            air_distance_m: r.6,
        })
        .collect())
}

pub(super) async fn ensure_snap_hint_table(pool: &PgPool) -> Result<(), anyhow::Error> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS osrm_snap_hints ( \
            source_scope TEXT NOT NULL, \
            endpoint_kind TEXT NOT NULL, \
            endpoint_id TEXT NOT NULL, \
            dataset_key TEXT NOT NULL, \
            input_lon DOUBLE PRECISION NOT NULL, \
            input_lat DOUBLE PRECISION NOT NULL, \
            snapped_lon DOUBLE PRECISION NOT NULL, \
            snapped_lat DOUBLE PRECISION NOT NULL, \
            hint TEXT NOT NULL, \
            snapped_distance_m DOUBLE PRECISION, \
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), \
            PRIMARY KEY (source_scope, endpoint_kind, endpoint_id, dataset_key) \
        )",
    )
    .execute(pool)
    .await?;

    sqlx::query(
        "CREATE INDEX IF NOT EXISTS osrm_snap_hints_lookup_idx \
         ON osrm_snap_hints (source_scope, endpoint_kind, dataset_key)",
    )
    .execute(pool)
    .await?;

    Ok(())
}

pub(super) async fn ensure_reachability_table(pool: &PgPool) -> Result<(), anyhow::Error> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS exit_place_scores (
            exit_id TEXT NOT NULL,
            place_id TEXT NOT NULL,
            route_distance_m INTEGER,
            route_duration_s INTEGER,
            reachable BOOLEAN,
            reachability_score DOUBLE PRECISION,
            reachability_confidence DOUBLE PRECISION,
            provider TEXT,
            provider_dataset_version TEXT,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (exit_id, place_id)
        )",
    )
    .execute(pool)
    .await?;

    Ok(())
}

pub(super) async fn flush_pending_updates(
    pool: &PgPool,
    pending: &mut PendingUpdates,
    dataset_version: Option<&str>,
) -> Result<(), anyhow::Error> {
    if pending.exit_ids.is_empty() {
        return Ok(());
    }

    sqlx::query(
        "INSERT INTO exit_place_scores \
         (exit_id, place_id, route_distance_m, route_duration_s, reachable, \
          reachability_score, reachability_confidence, provider, provider_dataset_version, updated_at) \
         SELECT \
            u.exit_id, \
            u.place_id, \
            NULLIF(u.route_distance_m, -1), \
            NULLIF(u.route_duration_s, -1), \
            u.reachable, \
            u.score, \
            u.confidence, \
            'osrm', \
            $8, \
            NOW() \
         FROM ( \
             SELECT \
                 UNNEST($1::text[]) AS exit_id, \
                 UNNEST($2::text[]) AS place_id, \
                 UNNEST($3::integer[]) AS route_distance_m, \
                 UNNEST($4::integer[]) AS route_duration_s, \
                 UNNEST($5::boolean[]) AS reachable, \
                 UNNEST($6::double precision[]) AS score, \
                 UNNEST($7::double precision[]) AS confidence \
         ) u \
         ON CONFLICT (exit_id, place_id) DO UPDATE \
         SET route_distance_m = EXCLUDED.route_distance_m, \
             route_duration_s = EXCLUDED.route_duration_s, \
             reachable = EXCLUDED.reachable, \
             reachability_score = EXCLUDED.reachability_score, \
             reachability_confidence = EXCLUDED.reachability_confidence, \
             provider = EXCLUDED.provider, \
             provider_dataset_version = EXCLUDED.provider_dataset_version, \
             updated_at = NOW()",
    )
    .bind(&pending.exit_ids)
    .bind(&pending.place_ids)
    .bind(&pending.route_distance_ms)
    .bind(&pending.route_duration_ss)
    .bind(&pending.reachables)
    .bind(&pending.scores)
    .bind(&pending.confidences)
    .bind(dataset_version)
    .execute(pool)
    .await?;

    pending.exit_ids.clear();
    pending.place_ids.clear();
    pending.route_distance_ms.clear();
    pending.route_duration_ss.clear();
    pending.scores.clear();
    pending.confidences.clear();
    pending.reachables.clear();

    Ok(())
}
