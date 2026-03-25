use super::*;
use reqwest::StatusCode;
use std::time::Duration;

pub(super) async fn fetch_nearest_snap(
    client: &reqwest::Client,
    osrm_url: &str,
    input: &SnapInputPoint,
    nearest_number: usize,
) -> Option<(SnapPoint, Option<f64>)> {
    let candidates = fetch_nearest_candidates(client, osrm_url, input, nearest_number).await?;
    candidates
        .into_iter()
        .next()
        .map(|candidate| (candidate.snap, candidate.snapped_distance_m))
}

async fn fetch_nearest_candidates(
    client: &reqwest::Client,
    osrm_url: &str,
    input: &SnapInputPoint,
    nearest_number: usize,
) -> Option<Vec<SnapCandidate>> {
    let url = format!(
        "{}/nearest/v1/driving/{:.7},{:.7}?number={}",
        osrm_url.trim_end_matches('/'),
        input.lon,
        input.lat,
        nearest_number.max(1)
    );

    for attempt in 0..3 {
        match client.get(url.as_str()).send().await {
            Ok(resp) => {
                if resp.status() == StatusCode::TOO_MANY_REQUESTS || resp.status().is_server_error()
                {
                    let wait = Duration::from_millis(150 * (attempt + 1) as u64);
                    tokio::time::sleep(wait).await;
                    continue;
                }

                let ok_resp = match resp
                    .error_for_status()
                    .context("OSRM nearest request failed")
                {
                    Ok(v) => v,
                    Err(_) => return None,
                };
                let parsed = match ok_resp
                    .json::<OsrmNearestResponse>()
                    .await
                    .context("parsing OSRM nearest response")
                {
                    Ok(v) => v,
                    Err(_) => return None,
                };

                if parsed.code != "Ok" {
                    if let Some(msg) = parsed.message.as_deref() {
                        tracing::debug!(
                            "OSRM nearest non-OK for endpoint {}: code={} message={}",
                            input.id,
                            parsed.code,
                            msg
                        );
                    }
                    return None;
                }

                let mut out = Vec::new();
                for waypoint in parsed.waypoints.unwrap_or_default() {
                    let location = match waypoint.location {
                        Some(loc) if loc.len() >= 2 => loc,
                        _ => continue,
                    };
                    out.push(SnapCandidate {
                        snap: SnapPoint {
                            lon: location[0],
                            lat: location[1],
                            hint: waypoint.hint.unwrap_or_default(),
                        },
                        snapped_distance_m: waypoint.distance,
                    });
                }

                if out.is_empty() {
                    return None;
                }
                return Some(out);
            }
            Err(_) => {
                let wait = Duration::from_millis(150 * (attempt + 1) as u64);
                tokio::time::sleep(wait).await;
            }
        }
    }

    None
}

pub(super) async fn resolve_exit_snap_candidate(
    client: &reqwest::Client,
    osrm_url: &str,
    input: &SnapInputPoint,
    probe_pairs: &[PendingPair],
) -> Option<(SnapPoint, Option<f64>, bool)> {
    let candidates =
        fetch_nearest_candidates(client, osrm_url, input, EXIT_NEAREST_CANDIDATE_COUNT).await?;
    let filtered = filter_exit_snap_candidates(candidates);
    if filtered.is_empty() {
        return None;
    }
    if filtered.len() == 1 {
        let selected = filtered.into_iter().next()?;
        return Some((selected.snap, selected.snapped_distance_m, false));
    }

    let mut probes: Vec<&PendingPair> = probe_pairs.iter().collect();
    probes.sort_by_key(|pair| pair.air_distance_m);
    probes.truncate(EXIT_SNAP_PROBE_PAIR_COUNT);

    if probes.is_empty() {
        let selected = choose_by_snap_distance(filtered.into_iter())?;
        return Some((selected.snap, selected.snapped_distance_m, true));
    }

    let mut best: Option<(f64, f64, SnapCandidate)> = None;
    for candidate in &filtered {
        let ratio = match probe_exit_candidate(client, osrm_url, candidate, &probes).await {
            Some(v) => v,
            None => continue,
        };
        let snap_distance = candidate.snapped_distance_m.unwrap_or(f64::INFINITY);
        match &best {
            Some((best_ratio, best_snap_distance, _))
                if ratio > *best_ratio
                    || (ratio == *best_ratio && snap_distance >= *best_snap_distance) => {}
            _ => best = Some((ratio, snap_distance, candidate.clone())),
        }
    }

    let selected = if let Some((_, _, candidate)) = best {
        candidate
    } else {
        choose_by_snap_distance(filtered.into_iter())?
    };

    Some((selected.snap, selected.snapped_distance_m, true))
}

fn filter_exit_snap_candidates(candidates: Vec<SnapCandidate>) -> Vec<SnapCandidate> {
    let mut primary = Vec::new();
    for candidate in &candidates {
        if candidate
            .snapped_distance_m
            .is_some_and(|d| d <= EXIT_SNAP_PRIMARY_RADIUS_M)
        {
            primary.push(candidate.clone());
        }
    }
    if !primary.is_empty() {
        return primary;
    }

    let mut relaxed = Vec::new();
    for candidate in &candidates {
        if candidate
            .snapped_distance_m
            .is_some_and(|d| d <= EXIT_SNAP_RELAXED_RADIUS_M)
        {
            relaxed.push(candidate.clone());
        }
    }
    if !relaxed.is_empty() {
        return relaxed;
    }

    candidates
}

fn choose_by_snap_distance<I>(candidates: I) -> Option<SnapCandidate>
where
    I: Iterator<Item = SnapCandidate>,
{
    let mut best: Option<SnapCandidate> = None;
    for candidate in candidates {
        let dist = candidate.snapped_distance_m.unwrap_or(f64::INFINITY);
        let best_dist = best
            .as_ref()
            .and_then(|c| c.snapped_distance_m)
            .unwrap_or(f64::INFINITY);
        if dist < best_dist {
            best = Some(candidate);
        }
    }
    best
}

async fn probe_exit_candidate(
    client: &reqwest::Client,
    osrm_url: &str,
    candidate: &SnapCandidate,
    probe_pairs: &[&PendingPair],
) -> Option<f64> {
    let mut coords = Vec::with_capacity(probe_pairs.len() + 1);
    let mut hints = Vec::with_capacity(probe_pairs.len() + 1);
    coords.push(format!(
        "{:.7},{:.7}",
        candidate.snap.lon, candidate.snap.lat
    ));
    hints.push(candidate.snap.hint.clone());

    for pair in probe_pairs {
        coords.push(format!("{:.7},{:.7}", pair.poi_lon, pair.poi_lat));
        hints.push(String::new());
    }

    let destinations = (1..coords.len())
        .map(|i| i.to_string())
        .collect::<Vec<_>>()
        .join(";");
    let mut url = reqwest::Url::parse(&format!(
        "{}/table/v1/driving/{}",
        osrm_url.trim_end_matches('/'),
        coords.join(";")
    ))
    .ok()?;
    {
        let mut qp = url.query_pairs_mut();
        qp.append_pair("sources", "0");
        qp.append_pair("destinations", &destinations);
        qp.append_pair("annotations", "distance");
        qp.append_pair("generate_hints", "false");
        qp.append_pair("hints", &hints.join(";"));
    }

    let table = fetch_osrm_table_with_retry(client, &url).await?;
    if table.code != "Ok" {
        return None;
    }
    let row_distances = table
        .distances
        .as_ref()
        .and_then(|d| d.first())
        .cloned()
        .unwrap_or_default();

    let mut ratios = Vec::new();
    for (idx, pair) in probe_pairs.iter().enumerate() {
        let route_m = row_distances.get(idx).and_then(|v| *v)?;
        let air_floor = (pair.air_distance_m as f64).max(SNAP_AIR_DISTANCE_FLOOR_M);
        ratios.push(route_m / air_floor);
    }
    if ratios.is_empty() {
        return None;
    }
    ratios.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let median = ratios[ratios.len() / 2];
    Some(median)
}

pub(super) async fn fetch_osrm_table_with_retry(
    client: &reqwest::Client,
    url: &reqwest::Url,
) -> Option<OsrmTableResponse> {
    let mut last_error: Option<anyhow::Error> = None;
    for attempt in 0..3 {
        match client.get(url.as_str()).send().await {
            Ok(resp) => {
                if resp.status() == StatusCode::TOO_MANY_REQUESTS || resp.status().is_server_error()
                {
                    let wait = Duration::from_millis(150 * (attempt + 1) as u64);
                    tokio::time::sleep(wait).await;
                    continue;
                }

                let ok_resp = match resp.error_for_status().context("OSRM table request failed") {
                    Ok(v) => v,
                    Err(err) => {
                        last_error = Some(err);
                        break;
                    }
                };
                match ok_resp
                    .json::<OsrmTableResponse>()
                    .await
                    .context("parsing OSRM table response")
                {
                    Ok(v) => return Some(v),
                    Err(err) => {
                        last_error = Some(err);
                        break;
                    }
                }
            }
            Err(err) => {
                last_error = Some(err.into());
                let wait = Duration::from_millis(150 * (attempt + 1) as u64);
                tokio::time::sleep(wait).await;
            }
        }
    }

    if let Some(err) = last_error {
        tracing::debug!("OSRM table call failed: {}", err);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(id: &str, snapped_distance_m: Option<f64>) -> SnapCandidate {
        SnapCandidate {
            snap: SnapPoint {
                lon: 0.0,
                lat: 0.0,
                hint: format!("hint-{id}"),
            },
            snapped_distance_m,
        }
    }

    #[test]
    fn filter_exit_snap_candidates_prefers_primary_radius() {
        let filtered = filter_exit_snap_candidates(vec![
            candidate("far", Some(40.0)),
            candidate("primary-a", Some(12.0)),
            candidate("primary-b", Some(7.0)),
        ]);
        assert_eq!(filtered.len(), 2);
        assert!(filtered
            .iter()
            .all(|entry| entry.snapped_distance_m.unwrap_or(f64::INFINITY) <= 15.0));
    }

    #[test]
    fn filter_exit_snap_candidates_uses_relaxed_radius_when_needed() {
        let filtered = filter_exit_snap_candidates(vec![
            candidate("relaxed-a", Some(20.0)),
            candidate("relaxed-b", Some(24.0)),
            candidate("far", Some(40.0)),
        ]);
        assert_eq!(filtered.len(), 2);
        assert!(filtered
            .iter()
            .all(|entry| entry.snapped_distance_m.unwrap_or(f64::INFINITY) <= 25.0));
    }

    #[test]
    fn choose_by_snap_distance_prefers_closest_candidate() {
        let chosen = choose_by_snap_distance(
            vec![
                candidate("farthest", Some(22.0)),
                candidate("closest", Some(3.0)),
                candidate("middle", Some(11.0)),
            ]
            .into_iter(),
        )
        .expect("expected a candidate");
        assert_eq!(chosen.snap.hint, "hint-closest");
    }
}
