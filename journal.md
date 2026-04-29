# Conversation Journal

## 2026-03-25 -- Initial Setup
- Repository created by Frank as part of the Automated Data Pipeline initiative
- Full proposal at /Users/tjohnell/projects/telegram-claude/pipeline-proposal.md
- Phase 1: Set up repo structure, AWS Batch infrastructure, containerize scoring binary

## 2026-03-25 -- Phase 1 Infrastructure Complete
- All 4 issues (#1-#4) implemented, reviewed by Frank, and merged via separate PRs (#5-#8)
- **PR #5 — CloudFormation template** (infra/cloudformation.yml): Two compute environments (on-demand + spot), two job queues, job definitions, S3 staging bucket with 7-day lifecycle, IAM roles (Batch + GHA OIDC with scoped permissions), CloudWatch billing alarm ($50/mo), conditional OIDC provider, explicit log groups with 14-day retention, us-east-1 enforcement
- **PR #6 — Dockerfile** (docker/Dockerfile): Multi-stage build. OSRM v5.27.1 built from source in builder stage, runtime image with osmium, PostgreSQL 15 + PostGIS 3 (cluster initialized), AWS CLI v2, gh CLI, scoring binary stub placeholder. Docker-build workflow pushes to GHCR on main push. .dockerignore added.
- **PR #7 — Pipeline scripts** (scripts/): osm-build.sh (marker-file resume, PBF cleanup), score.sh (OSRM health check, dynamic PG version, CSV schema validation, explicit CSV paths), create-ebs.sh, delete-ebs.sh (tag safety, force-detach fallback), submit-batch-job.sh (jq JSON, EBS_VOLUME_ID + OI_RELEASE_TAG env vars), setup-aws.sh (VPC auto-detect)
- **PR #8 — score.yml workflow** (.github/workflows/score.yml): Full pipeline orchestration with polling guards, OI release tag resolution, CROSS_REPO_TOKEN for downstream dispatch, duration tracking in release body, always-run EBS cleanup
- To test-drive: add 3 secrets (AWS_ROLE_ARN, AWS_ACCOUNT_ID, CROSS_REPO_TOKEN), run setup-aws.sh to deploy CloudFormation stack, then trigger workflow manually
- Scoring binary integration still TODO (Dockerfile has stub placeholder)

## 2026-03-25 -- Integration Fixes Complete
- Frank filed integration issues #9-#11 after reviewing the full pipeline end-to-end
- **PR #12 — EBS self-attachment** (issue #9): LaunchTemplate with HttpPutResponseHopLimit: 2 on both compute environments (IMDSv2 from containers), tag-scoped EC2 permissions on Batch job role, mount-ebs.sh and unmount-ebs.sh scripts for container-level EBS attach/detach via IMDSv2, osm-build.sh single EXIT trap, stale MountPoints/Volumes removed from CloudFormation job definitions
- **PR #13 — Duration fix** (issue #11): Replaced $SECONDS (resets per GHA step) with epoch-based timing captured in run-id step and calculated in release step
- **PR #14 — OI release via S3** (issue #10): Moved OI release download from Batch container (no GitHub auth) to GHA workflow (has CROSS_REPO_TOKEN), stages tarball to S3, score.sh pulls from S3 using IAM role. Removed silent fallback to "latest" on tag resolution failure.
- All 11 issues closed, pipeline is complete and ready for test-drive

## 2026-03-25 -- oi-score Extraction Complete
- **PR #16 — oi-score binary** (issue #15): Extracted reachability scoring engine (7 files, 1,862 lines) into standalone oi-score binary.
  - New Cargo.toml with 8 crate deps (tokio, sqlx 0.8, serde, reqwest 0.12, clap 4, tracing, anyhow)
  - 3-stage Dockerfile: Rust build (with dep caching layer) → OSRM build → runtime
  - score.sh creates tables matching OI CSV schema, extracts lat/lon from places geometry_geojson
  - score.sh exports results from exit_place_scores table to CSV via psql \copy
  - All 7 unit tests pass
- Pipeline is now feature-complete (12 issues, 8 PRs). To test-drive: add AWS secrets, deploy CloudFormation, trigger workflow.

## 2026-03-25 -- Pipeline Debugging (PRs #34-#39)

Worked through 5 successive blockers in the scoring pipeline, each fix getting further:

1. **PR #34 — OSRM file check**: score.sh checked for `.osrm` but OSRM v5.27.1 produces `.osrm.nbg_nodes` etc. Fixed existence check.
2. **PR #35 — EBS volume reuse**: Added `ebs_volume_id` workflow input to skip osm-build phase, saving ~90 min per retry.
3. **PR #36 — Score job memory**: OSRM CONUS MLD needs ~47GB+ RAM. Increased score job from 28GB→120GB, 4→16 vCPUs.
4. **PR #37 — OSRM startup timeout**: OSRM takes ~325s to load 60GB dataset. Increased health check from 5→15 min.
5. **PR #38 — Duplicate exit IDs**: OI CSVs contain duplicate exit_id values. Removed PRIMARY KEY from CREATE TABLE, load via \copy, then dedup with ctid trick, then add UNIQUE INDEX.
6. **PR #39 — oi-score clap arg parsing**: Root cause of "relation exit_place_scores does not exist" error. `oi-score score --database-url ...` silently fails because clap 4 doesn't allow parent args after a subcommand. Fixed by: (a) removing explicit `score` subcommand from score.sh invocation, (b) adding `global = true` to all CLI args. Confirmed with new test that reproduces the exact failure.

EBS volume vol-041f5aa784f19c00e from run 23554122059-1 has been reused across retries. After PR #39 merge + Docker rebuild, pipeline should complete end-to-end.

## 2026-03-25 -- Pipeline Debugging (PRs #40-#42)

Three more fixes after PR #39, all related to oi-score producing zero output:

7. **PR #40 — Docker registry cache**: `cache-from: type=registry` served stale cached layers, preventing source code changes from being compiled. Removed `cache-from`/`cache-to` from docker-build.yml.
8. **PR #41 — Cargo timestamp caching**: Docker COPY preserves file timestamps from the build context. The Dockerfile's dep-caching trick (dummy main.rs → build deps → rm src → COPY real src → rebuild) broke because the cached binary had a newer timestamp than the real source files. Cargo skipped recompilation. Fixed by adding `touch src/main.rs src/**/*.rs` before `cargo build`. This was the root cause — oi-score had literally never been compiled from real source code in any Docker image.
9. **PR #42 — Duplicate exit_place_links**: exit_place_links had ~53k duplicate (exit_id, place_id) pairs. When duplicates landed in the same 25k-row UNNEST batch, PostgreSQL raised "ON CONFLICT DO UPDATE cannot affect row a second time." Fixed by: (a) deduplicating exit_place_links in score.sh after CSV load, (b) adding DISTINCT to fetch_pending_pairs query in db.rs.

## 2026-03-26 -- Pipeline Success

Run 23572441119 completed successfully in 21 minutes. 200,615 reachability scores published as release `score-20260326-6c28d57`. Pipeline is fully operational end-to-end: GHA workflow → AWS Batch osm-build → score job (OSRM + PostGIS + oi-score) → CSV export → S3 upload → GitHub release → repository_dispatch to downstream consumer.

Total: 42 PRs from first commit to first successful run.

## 2026-03-27 -- Rebrand to openinterstate-reachability

Renamed repo to tldev/openinterstate-reachability. Scrubbed all references to the old name across the codebase: binary renamed to oi-score, AWS resources renamed, database user/name updated, CLAUDE.md/README/journal rewritten. CloudFormation stack will need redeployment with new resource names. One external repo reference remains in score.yml dispatch target (cannot be renamed from this repo).

## 2026-04-01 -- Park/DogPark Categories + AZ Pinning

OI shipped park and dogPark POI categories. Ran a fresh scoring pipeline to include them.

**osmium filter update (b7ee45a):** Added `n/leisure=park,dog_park` and `w/leisure=park,dog_park` to osm-build.sh osmium tags-filter. This was the only change needed in this repo — POI classification and name-filter exceptions live upstream in OI's derive.sql.

**AZ mismatch fix (86d29c0, 7f5e047, c159d20):** After the CloudFormation rebrand redeploy, the compute environment had subnets in us-east-1a and us-east-1b. EBS volumes are AZ-pinned but Batch instances can land in either AZ. Retries didn't help — Batch reuses the same warm instance. Fix: workflow now pins compute environments to the EBS volume's AZ subnet before submitting jobs, restores original subnets in always-run cleanup.

**Supporting changes:**
- EBS volume preserved on failure (c877e46) — delete only on success(), print volume ID on failure for ebs_volume_id reuse
- Added batch:DescribeComputeEnvironments + batch:UpdateComputeEnvironment IAM permissions (f4a8bcf)
- AZ pre-check in mount-ebs.sh via IMDSv2 (86d29c0)
- Fixed spot CE name (compute-spot, not compute-spot-v2) and multi-line JSON in GITHUB_OUTPUT (c159d20)

**Result:** Run 23853449693 succeeded in 1h 57m. Release `score-20260401-c159d20`: 313,472 scores (up from 200,615 — parks added ~113k new exit-POI pairs). Downstream dispatch sent to pike.
