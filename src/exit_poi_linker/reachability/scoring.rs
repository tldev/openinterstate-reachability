use super::osrm::fetch_osrm_table_with_retry;
use super::*;

pub(super) async fn score_exit_batch(
    client: &reqwest::Client,
    osrm_url: &str,
    batch: ExitBatch,
    exit_snap_hints: &HashMap<String, SnapPoint>,
    poi_snap_hints: &HashMap<String, SnapPoint>,
) -> Result<Vec<UpdateRow>, anyhow::Error> {
    let url = build_osrm_table_url(&batch, osrm_url, exit_snap_hints, poi_snap_hints)?;
    let table = match fetch_osrm_table_with_retry(client, &url).await {
        Some(v) => v,
        None => {
            tracing::warn!("OSRM table request failed for exit {}", batch.exit_id);
            return Ok(unreachable_updates(batch.pairs));
        }
    };

    if table.code != "Ok" {
        let msg = table
            .message
            .as_deref()
            .unwrap_or("no error message provided by OSRM");
        tracing::warn!(
            "OSRM table non-OK response for exit {}: code={} message={}",
            batch.exit_id,
            table.code,
            msg
        );
        return Ok(unreachable_updates(batch.pairs));
    }

    Ok(updates_from_table(batch.pairs, &table))
}

fn build_osrm_table_url(
    batch: &ExitBatch,
    osrm_url: &str,
    exit_snap_hints: &HashMap<String, SnapPoint>,
    poi_snap_hints: &HashMap<String, SnapPoint>,
) -> Result<reqwest::Url, anyhow::Error> {
    let (coords, hints) = build_coords_and_hints(batch, exit_snap_hints, poi_snap_hints);
    let destinations = (1..coords.len())
        .map(|index| index.to_string())
        .collect::<Vec<_>>()
        .join(";");

    let mut url = reqwest::Url::parse(&format!(
        "{}/table/v1/driving/{}",
        osrm_url.trim_end_matches('/'),
        coords.join(";")
    ))
    .context("building OSRM table URL")?;
    {
        let mut qp = url.query_pairs_mut();
        qp.append_pair("sources", "0");
        qp.append_pair("destinations", &destinations);
        qp.append_pair("annotations", "distance,duration");
        qp.append_pair("generate_hints", "false");
        qp.append_pair("hints", &hints.join(";"));
    }

    Ok(url)
}

fn build_coords_and_hints(
    batch: &ExitBatch,
    exit_snap_hints: &HashMap<String, SnapPoint>,
    poi_snap_hints: &HashMap<String, SnapPoint>,
) -> (Vec<String>, Vec<String>) {
    let mut coords = Vec::with_capacity(batch.pairs.len() + 1);
    let mut hints = Vec::with_capacity(batch.pairs.len() + 1);

    let exit_snap = exit_snap_hints.get(&batch.exit_id);
    let exit_lon = exit_snap.map(|snap| snap.lon).unwrap_or(batch.exit_lon);
    let exit_lat = exit_snap.map(|snap| snap.lat).unwrap_or(batch.exit_lat);
    let exit_hint = exit_snap
        .map(|snap| snap.hint.as_str())
        .unwrap_or_default()
        .to_string();

    coords.push(format!("{exit_lon:.7},{exit_lat:.7}"));
    hints.push(exit_hint);

    for pair in &batch.pairs {
        let poi_snap = poi_snap_hints.get(&pair.poi_id);
        let poi_lon = poi_snap.map(|snap| snap.lon).unwrap_or(pair.poi_lon);
        let poi_lat = poi_snap.map(|snap| snap.lat).unwrap_or(pair.poi_lat);
        let poi_hint = poi_snap
            .map(|snap| snap.hint.as_str())
            .unwrap_or_default()
            .to_string();

        coords.push(format!("{poi_lon:.7},{poi_lat:.7}"));
        hints.push(poi_hint);
    }

    (coords, hints)
}

fn unreachable_updates(pairs: Vec<PendingPair>) -> Vec<UpdateRow> {
    pairs.into_iter().map(unreachable_update).collect()
}

fn unreachable_update(pair: PendingPair) -> UpdateRow {
    let (score, confidence) = unreachable_score(pair.air_distance_m);
    UpdateRow {
        exit_id: pair.exit_id,
        poi_id: pair.poi_id,
        route_distance_m: None,
        route_duration_s: None,
        score,
        confidence,
        reachable: false,
    }
}

fn updates_from_table(pairs: Vec<PendingPair>, table: &OsrmTableResponse) -> Vec<UpdateRow> {
    let row_distances = table
        .distances
        .as_ref()
        .and_then(|d| d.first())
        .cloned()
        .unwrap_or_default();
    let row_durations = table
        .durations
        .as_ref()
        .and_then(|d| d.first())
        .cloned()
        .unwrap_or_default();

    let mut updates = Vec::with_capacity(pairs.len());
    for (idx, pair) in pairs.into_iter().enumerate() {
        let dist = row_distances.get(idx).and_then(|v| *v);
        let dur = row_durations.get(idx).and_then(|v| *v);

        if let Some(route_m) = dist {
            updates.push(reachable_update(pair, route_m, dur));
        } else {
            updates.push(unreachable_update(pair));
        }
    }

    updates
}

fn reachable_update(
    pair: PendingPair,
    route_distance_raw_m: f64,
    duration_raw_s: Option<f64>,
) -> UpdateRow {
    let route_distance_m = route_distance_raw_m.round().clamp(0.0, i32::MAX as f64) as i32;
    let route_duration_s = duration_raw_s
        .map(|value| value.round().clamp(0.0, i32::MAX as f64) as i32)
        .unwrap_or(route_distance_m / 25);
    let (score, confidence) = reachable_score(route_distance_m, pair.air_distance_m);

    UpdateRow {
        exit_id: pair.exit_id,
        poi_id: pair.poi_id,
        route_distance_m: Some(route_distance_m),
        route_duration_s: Some(route_duration_s),
        score,
        confidence,
        reachable: true,
    }
}

fn reachable_score(route_distance_m: i32, air_distance_m: i32) -> (f64, f64) {
    let distance_penalty = (route_distance_m as f64 / 10.0).min(70.0);
    let offset_penalty = (air_distance_m as f64 / 15.0).min(20.0);
    let score = (100.0 - distance_penalty - offset_penalty).clamp(0.0, 100.0);

    let confidence = if route_distance_m <= 1_500 {
        0.95
    } else if route_distance_m <= 4_000 {
        0.90
    } else if route_distance_m <= 8_000 {
        0.82
    } else {
        0.75
    };

    (score, confidence)
}

fn unreachable_score(air_distance_m: i32) -> (f64, f64) {
    let confidence = if air_distance_m <= 80 {
        0.80
    } else if air_distance_m <= 180 {
        0.65
    } else {
        0.50
    };
    (0.0, confidence)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reachable_score_drops_as_route_distance_increases() {
        let (near_score, near_confidence) = reachable_score(300, 120);
        let (far_score, far_confidence) = reachable_score(6_500, 120);
        assert!(near_score > far_score);
        assert!(near_confidence > far_confidence);
    }

    #[test]
    fn unreachable_score_confidence_drops_for_farther_air_distance() {
        let (_, near_confidence) = unreachable_score(60);
        let (_, mid_confidence) = unreachable_score(120);
        let (_, far_confidence) = unreachable_score(250);
        assert!(near_confidence > mid_confidence);
        assert!(mid_confidence > far_confidence);
    }
}
