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
