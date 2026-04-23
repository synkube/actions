This copy tracks [Checkmarx/kics-github-action](https://github.com/Checkmarx/kics-github-action) (GPL-3.0). Differences in this repository:

- **KICS base image** is pinned by digest in `Dockerfile` so CI builds a consistent engine binary layer:

  `docker.io/checkmarx/kics:v2.1.20@sha256:3e5a268eb8adda2e5a483c9359ddfc4cd520ab856a7076dc0b1d8784a37e2602`

- **`action.yml`**: the `config_path` input is wired correctly in `runs.args` (upstream used a non-existent `inputs.config` expression).

The runtime base image `cgr.dev/chainguard/wolfi-base:latest` is unchanged from upstream; consider pinning it by digest in a follow-up for full reproducibility.
