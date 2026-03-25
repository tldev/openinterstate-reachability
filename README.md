# pike-reachability

Automated reachability scoring pipeline for Pike. Computes driving distances and times between highway exits and nearby POIs using OSRM routing.

## How it works

1. Downloads and processes US road network data (PBF -> OSRM)
2. Fetches exit and POI locations from the latest OpenInterstate release
3. Scores ~467k exit-POI pairs using OSRM table routing
4. Publishes reachability CSV as a GitHub release artifact

## Infrastructure

- **Compute:** AWS Batch (ephemeral EC2 instances, no persistent infra)
- **Orchestration:** GitHub Actions
- **Output:** Reachability CSV (~28 MB) consumed by Pike's build-pack workflow

## Cost

~$5/month (spot instances + ephemeral EBS)
