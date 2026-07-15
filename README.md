# OpenInterstate Reachability

Proximity is a poor predictor of drivability around highway interchanges: a
gas station 200 meters from an exit can be a five-minute detour, or
unreachable from that side of the highway. This project computes real driving
routes for every exit-place pair in an
[OpenInterstate](https://github.com/tldev/openinterstate) release and
publishes the scores as open data.

## Get the data

Each scoring run publishes a `score-*` release on the
[releases page](https://github.com/tldev/openinterstate-reachability/releases),
pinned in its notes to the exact OpenInterstate release it scored:

```bash
gh release download --repo tldev/openinterstate-reachability --pattern reachability.csv
```

- `reachability.csv` holds OSRM driving distance and duration, a reachable
  flag, a 0 to 100 score, and a confidence value per exit-place pair. Rows
  join back to the source release through `exit_id` and `place_id`.
- `osrm_snap_hints.csv` holds cached road-network snap points that make later
  runs incremental.

Every column is documented in [datapackage.json](datapackage.json) (Data
Package standard) and rendered at <https://openinterstate.org/schema>. The
data is OpenStreetMap-derived and published under ODbL 1.0.

## Scoring model

OSRM computes a driving route for each pair. The score starts at 100 and
subtracts a route-distance penalty (up to 70 points) and an exit-offset
penalty (up to 20 points); unreachable pairs score 0. Confidence steps down
from 0.95 as route distance grows.

## How it runs

One GitHub Actions workflow (`score.yml`) orchestrates two AWS Batch jobs
with no persistent infrastructure:

1. `osm-build` (on-demand EC2): downloads the US PBF, filters it, and builds
   the OSRM dataset onto an ephemeral EBS volume. This takes hours and is not
   resumable, so it runs on-demand.
2. `score` (spot EC2, three retries): mounts the volume, fetches the
   OpenInterstate release, scores every exit-place pair, and uploads the CSV.
   Scoring is resumable through snap hints, so spot interruptions are cheap.

The volume is deleted when the run finishes. A successful run publishes the
`score-*` release and sends a `reachability-release` repository_dispatch to
the repo named by the `DOWNSTREAM_DISPATCH_REPO` variable, when set.

Triggers: a `repository_dispatch` of type `oi-release`, or a manual
`workflow_dispatch` that can pin `oi_release_tag` or reuse an existing OSRM
volume via `ebs_volume_id`.

## Run your own

1. Deploy the CloudFormation stack:
   `scripts/setup-aws.sh --email <alarm-email>` (auto-detects the default
   VPC, or pass `--vpc` and `--subnets`).
2. Set the `AWS_ACCOUNT_ID` and `AWS_ROLE_ARN` repository secrets from the
   printed outputs.
3. Optionally set the `DOWNSTREAM_DISPATCH_REPO` repository variable and a
   `CROSS_REPO_TOKEN` secret to notify a downstream consumer.
4. Run the `Reachability Scoring Pipeline` workflow.

The stack includes Batch job timeouts, a workflow timeout, and a monthly
CloudWatch billing alarm.
