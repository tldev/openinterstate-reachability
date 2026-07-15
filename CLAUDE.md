# OpenInterstate Reachability

## What This Project Does

OpenInterstate Reachability computes driving reachability scores between
highway exits and nearby POIs (gas stations, restaurants, hotels, etc.). It
takes OpenInterstate release data (exit locations + POI locations) and uses
OSRM routing to determine actual drive times and distances for each exit-POI
pair.

The output is a reachability CSV uploaded as a GitHub release artifact,
described by `datapackage.json`. Downstream consumers pair it with the
matching OpenInterstate release.

## Architecture

This repo contains two AWS Batch jobs orchestrated by a single GitHub Actions workflow:

```
GHA workflow: score.yml
  |
  +-- Job 1: osm-build (on-demand EC2, r6i.2xlarge)
  |     Download US PBF -> filter with osmium -> build OSRM dataset
  |     Write to ephemeral EBS volume (~82 GB)
  |
  +-- Job 2: score (spot EC2, r6i.xlarge, 3 retries)
  |     Mount same EBS -> start OSRM + PostGIS -> fetch OI release
  |     Run oi-score -> output reachability CSV
  |
  +-- Upload CSV as GitHub release artifact
  +-- Delete ephemeral EBS volume
  +-- Send repository_dispatch to the configured downstream consumer
      (repo variable DOWNSTREAM_DISPATCH_REPO; skipped when unset)
```

### Key Properties

- **No persistent infrastructure.** EBS volume is created per pipeline run and deleted on completion. No lingering resources.
- **osm-build uses on-demand instances.** OSRM extract/contract is not resumable -- a spot interruption would lose hours of work.
- **Scoring uses spot instances with 3 retries.** Scoring is resumable (snap hints cached, rows upserted). Spot interruptions are handled gracefully.
- **Output is CSV, not pgdump.** Eliminates PostGIS dependency from downstream consumers.
- **Safety rails:** Batch job timeouts (8h/6h), GHA workflow timeout (16h), CloudWatch billing alarm ($50/mo), EBS cleanup in always-run step.

## Repository Structure

```
openinterstate-reachability/
  .github/workflows/
    score.yml            # Main workflow: osm-build + score + release
    docker-build.yml     # Tool image build/push to ghcr
  docker/
    Dockerfile           # oi-score + OSRM + PostgreSQL (multi-stage)
  infra/
    cloudformation.yml   # Batch compute environments, roles, queue, alarms
  scripts/
    osm-build.sh         # Download PBF, filter, build OSRM
    score.sh             # Load seed, run scoring, output CSV
    create-ebs.sh        # AWS CLI: create + tag EBS volume
    delete-ebs.sh        # AWS CLI: delete EBS volume
    mount-ebs.sh         # Container-level EBS attach via IMDSv2
    unmount-ebs.sh       # Container-level EBS detach
    submit-batch-job.sh  # AWS CLI: submit Batch job with EBS attachment
    setup-aws.sh         # One-time AWS account bootstrap
  src/                   # Rust scoring pipeline (exit_poi_linker)
  datapackage.json       # Schema for published tables (Data Package standard)
```

## Related Projects

- **openinterstate** (tldev/openinterstate): Produces exit + POI CSVs as GitHub releases. Input to scoring.

## AWS Resources

- Batch Compute Environments: openinterstate-reachability-compute-ondemand-v2, openinterstate-reachability-compute-spot
- Batch Job Queue: openinterstate-reachability-queue
- Job Definitions: openinterstate-reachability-osm-build, openinterstate-reachability-score
- S3 Bucket: openinterstate-reachability-staging (7-day lifecycle)
- IAM Roles: openinterstate-reachability-batch-role, openinterstate-reachability-gha-role (OIDC)
- CloudWatch Alarm: openinterstate-reachability-cost-alarm ($50/mo threshold)

## Technical Details

- OSRM CONUS dataset: ~82 GB (mldgr file alone is 7 GB)
- OSRM needs ~16 GB RAM for CONUS MLD routing
- Scoring runs 16 parallel OSRM table requests
- Pair count and scoring duration scale with the OpenInterstate release's
  exit-place links (hundreds of thousands of pairs, tens of minutes on
  r6i.xlarge)
- US PBF download: ~11 GB from Geofabrik
