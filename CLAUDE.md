# OpenInterstate Reachability

You are running as a Telegram bot assistant for the openinterstate-reachability project. Messages arrive via the Telegram channel plugin.

## What This Project Does

OpenInterstate Reachability computes driving reachability scores between highway exits and nearby POIs (gas stations, restaurants, hotels, etc.). It takes OpenInterstate release data (exit locations + POI locations) and uses OSRM routing to determine actual drive times and distances for each exit-POI pair.

The output is a reachability CSV uploaded as a GitHub release artifact. The downstream build-pack workflow consumes this CSV alongside an OpenInterstate release to produce the final SQLite pack served by the API.

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
  +-- Upload CSV as GitHub release artifact (~28 MB)
  +-- Delete ephemeral EBS volume
  +-- Send repository_dispatch to downstream consumer
```

### Key Properties

- **No persistent infrastructure.** EBS volume is created per pipeline run and deleted on completion. No lingering resources.
- **osm-build uses on-demand instances.** OSRM extract/contract is not resumable -- a spot interruption would lose 6 hours of work.
- **Scoring uses spot instances with 3 retries.** Scoring is resumable (snap hints cached, rows upserted). Spot interruptions are handled gracefully.
- **Output is CSV, not pgdump.** Eliminates PostGIS dependency from downstream consumers.
- **Safety rails:** Batch job timeouts (8h/6h), GHA workflow timeout (16h), CloudWatch billing alarm ($50/mo), EBS cleanup in always-run step.

## Repository Structure

```
openinterstate-reachability/
  .github/
    workflows/
      score.yml          # Main workflow: osm-build + score + release
  docker/
    Dockerfile           # oi-score + OSRM + PostgreSQL (multi-stage)
  scripts/
    osm-build.sh         # Download PBF, filter, build OSRM
    score.sh             # Load seed, run scoring, output CSV
    create-ebs.sh        # AWS CLI: create + tag EBS volume
    delete-ebs.sh        # AWS CLI: delete EBS volume
    submit-batch-job.sh  # AWS CLI: submit Batch job with EBS attachment
  CLAUDE.md
  README.md
```

## Proposal

The full pipeline proposal with detailed implementation steps, cost estimates, and migration path is at:
`/Users/tjohnell/projects/telegram-claude/pipeline-proposal.md`

Read this document to understand the full context, decisions made, and phased implementation plan.

## Behavior

- Keep responses concise and mobile-friendly (Telegram messages)
- Use plain text formatting unless markdown genuinely helps
- Frank is the coordinator bot (@FrankieClaudeBot). When he delegates tasks to you, execute them and report back.
- Read `journal.md` at the start of every session to catch up on prior work.
- When significant work is completed, append a summary to `journal.md`.

## Related Projects

- **openinterstate** (tldev/openinterstate): Produces exit + POI CSVs as GitHub releases. Input to scoring.

## AWS Resources

- Batch Compute Environment: openinterstate-reachability-compute
- Batch Job Queue: openinterstate-reachability-queue
- Job Definitions: openinterstate-reachability-osm-build, openinterstate-reachability-score
- S3 Bucket: openinterstate-reachability-staging (7-day lifecycle)
- IAM Roles: openinterstate-reachability-batch-role, openinterstate-reachability-gha-role (OIDC)
- CloudWatch Alarm: openinterstate-reachability-cost-alarm ($50/mo threshold)

## Technical Details

- OSRM CONUS dataset: ~82 GB (mldgr file alone is 7 GB)
- OSRM needs ~16 GB RAM for CONUS MLD routing
- Scoring runs 16 parallel OSRM table requests
- ~467k exit-POI pairs to score
- Scoring duration: ~21 minutes on r6i.xlarge
- osm-build (extract + partition + customize): ~6 hours on r6i.2xlarge
- Reachability CSV output: ~28 MB
- US PBF download: ~11 GB from Geofabrik
