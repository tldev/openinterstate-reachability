# Conversation Journal

## 2026-03-25 -- Initial Setup
- Repository created by Frank as part of the Pike Automated Data Pipeline initiative
- Full proposal at /Users/tjohnell/projects/telegram-claude/pike-pipeline-proposal.md
- Phase 1: Set up repo structure, AWS Batch infrastructure, containerize pike-import score

## 2026-03-25 -- Phase 1 Infrastructure Complete
- All 4 issues (#1-#4) implemented, reviewed by Frank, and merged via separate PRs (#5-#8)
- **PR #5 — CloudFormation template** (infra/cloudformation.yml): Two compute environments (on-demand + spot), two job queues, job definitions, S3 staging bucket with 7-day lifecycle, IAM roles (Batch + GHA OIDC with scoped permissions), CloudWatch billing alarm ($50/mo), conditional OIDC provider, explicit log groups with 14-day retention, us-east-1 enforcement
- **PR #6 — Dockerfile** (docker/Dockerfile): Multi-stage build. OSRM v5.27.1 built from source in builder stage, runtime image with osmium, PostgreSQL 15 + PostGIS 3 (cluster initialized), AWS CLI v2, gh CLI, pike-import stub placeholder. Docker-build workflow pushes to GHCR on main push. .dockerignore added.
- **PR #7 — Pipeline scripts** (scripts/): osm-build.sh (marker-file resume, PBF cleanup), score.sh (OSRM health check, dynamic PG version, CSV schema validation, explicit CSV paths), create-ebs.sh, delete-ebs.sh (tag safety, force-detach fallback), submit-batch-job.sh (jq JSON, EBS_VOLUME_ID + OI_RELEASE_TAG env vars), setup-aws.sh (VPC auto-detect)
- **PR #8 — score.yml workflow** (.github/workflows/score.yml): Full pipeline orchestration with polling guards, OI release tag resolution, CROSS_REPO_TOKEN for pike dispatch, duration tracking in release body, always-run EBS cleanup
- To test-drive: add 3 secrets (AWS_ROLE_ARN, AWS_ACCOUNT_ID, CROSS_REPO_TOKEN), run setup-aws.sh to deploy CloudFormation stack, then trigger workflow manually
- pike-import binary integration still TODO (Dockerfile has stub placeholder)

## 2026-03-25 -- Integration Fixes Complete
- Frank filed integration issues #9-#11 after reviewing the full pipeline end-to-end
- **PR #12 — EBS self-attachment** (issue #9): LaunchTemplate with HttpPutResponseHopLimit: 2 on both compute environments (IMDSv2 from containers), tag-scoped EC2 permissions on Batch job role, mount-ebs.sh and unmount-ebs.sh scripts for container-level EBS attach/detach via IMDSv2, osm-build.sh single EXIT trap, stale MountPoints/Volumes removed from CloudFormation job definitions
- **PR #13 — Duration fix** (issue #11): Replaced $SECONDS (resets per GHA step) with epoch-based timing captured in run-id step and calculated in release step
- **PR #14 — OI release via S3** (issue #10): Moved OI release download from Batch container (no GitHub auth) to GHA workflow (has CROSS_REPO_TOKEN), stages tarball to S3, score.sh pulls from S3 using IAM role. Removed silent fallback to "latest" on tag resolution failure.
- All 11 issues closed, pipeline is complete and ready for test-drive

## 2026-03-25 -- pike-score Extraction Complete
- **PR #16 — pike-score binary** (issue #15): Extracted reachability scoring engine (7 files, 1,862 lines) from tldev/pike into standalone pike-score binary. Zero shared code with other pike modules.
  - New Cargo.toml with 8 crate deps (tokio, sqlx 0.8, serde, reqwest 0.12, clap 4, tracing, anyhow)
  - 3-stage Dockerfile: Rust build (with dep caching layer) → OSRM build → runtime
  - score.sh creates tables matching OI CSV schema, extracts lat/lon from places geometry_geojson
  - score.sh exports results from exit_place_scores table to CSV via psql \copy
  - All 7 unit tests pass
- Pipeline is now feature-complete (12 issues, 8 PRs). To test-drive: add AWS secrets, deploy CloudFormation, trigger workflow.
