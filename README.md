# synkube/actions

Reusable GitHub Actions for the synkube organization.

## Actions

| Path | Description |
| --- | --- |
| [.github/actions/gitops-bump](.github/actions/gitops-bump) | Bump `# github-workflow-managed` Helm values in a GitOps repo (push or pull request; used by [Deploy workflow](.github/workflows/deploy.yaml)) |
| [.github/actions/jwt-exchange](.github/actions/jwt-exchange) | Exchange GitHub Actions OIDC for a short-lived GitHub App installation token via [synkube/jwt-exchange](https://github.com/synkube/jwt-exchange) (`/api/v2/exchange/token`, bash composite) |
| [.github/actions/kics-github-action](.github/actions/kics-github-action) | [KICS](https://kics.io/) static analysis for Infrastructure as Code (fork of [Checkmarx/kics-github-action](https://github.com/Checkmarx/kics-github-action) with a digest-pinned KICS engine image) |
| [.github/actions/trivy-fs](.github/actions/trivy-fs) | Trivy filesystem (dependency) scan with optional SARIF upload to GHAS |
| [.github/actions/trivy-image](.github/actions/trivy-image) | Trivy container image scan with optional SARIF upload to GHAS |

## Workflows

| Path | Description |
| --- | --- |
| [.github/workflows/deploy.yaml](.github/workflows/deploy.yaml) | Reusable GitOps deploy — OIDC exchange + bump `# github-workflow-managed` values + push or PR |
| [.github/workflows/docker-build-push.yaml](.github/workflows/docker-build-push.yaml) | Reusable Docker build — GHCR push on main, semver git tag, optional Trivy image scan |
| [.github/workflows/kics-scan.yaml](.github/workflows/kics-scan.yaml) | Reusable KICS IaC scan — digest-pinned engine, central exclude-queries, optional SARIF |
| [.github/workflows/sha-tag.yaml](.github/workflows/sha-tag.yaml) | Resolve composite SHA suffix tag from latest git tag |

## Usage

Org convention: **`uses`** is pinned to the **full commit SHA** of this repo; the **release tag** (e.g. **`v1.0.0`**) appears **only in the trailing comment** so reviewers know which release line you intend.

```yaml
- uses: synkube/actions/.github/actions/kics-github-action@9f425ac79ec75ce388b4e27528784a095a272584 # v1.0.0
  with:
    path: terraform
```

When you cut a new release, bump the SHA to the commit that tag points at and update the comment (e.g. `# v1.0.1`).

### KICS IaC scan (reusable workflow)

Thin caller — path filters and the `CI_G_KICS_ENABLED` gate stay in the consuming repo; scanning lives here.

```yaml
name: KICS IaC Scan

permissions:
  contents: read
  security-events: write
  actions: read

on:
  push:
    paths: ["**/*.tf", "**/*.yaml", "**/*.yml"]
  pull_request:
    paths: ["**/*.tf", "**/*.yaml", "**/*.yml"]
  workflow_dispatch:

jobs:
  kics:
    if: vars.CI_G_KICS_ENABLED != 'false'
    uses: synkube/actions/.github/workflows/kics-scan.yaml@<sha> # after merge, pin the commit
    with:
      scan_path: .
      # ignore_on_exit: results   # default — advisory (job stays green on findings)
      # fail_on: critical,high    # use with ignore_on_exit: none to gate PRs
      # sarif_report_enabled: true  # needs GHAS / Code Security on the repo
```

| Input | Default | Description |
| --- | --- | --- |
| `scan_path` | `.` | Path relative to repo root |
| `ignore_on_exit` | `results` | Ignore KICS exit caused by findings (`none` / `results` / `errors` / `all`) |
| `fail_on` | _(empty)_ | Severities that make KICS exit non-zero (only gates when `ignore_on_exit` is not `results`/`all`) |
| `config_path` | _(empty)_ | Optional repo-local kics.config; else repo-root `kics.config`; else embedded central excludes |
| `sarif_report_enabled` | `false` | Upload SARIF to code scanning |
| `sarif_category` | `kics-iac` | Code scanning category |
| `upload_artifacts` | `false` | Always upload `kics-results/` (also uploads when SARIF is on) |

### Multiple images (one job per image)

Each image gets its own matrix row; GitHub runs one reusable-workflow job per row in parallel. Pair each row with a matching `deploy.yaml` call (`tag_prefix` + `managed_key`).

```yaml
jobs:
  docker:
    strategy:
      fail-fast: false
      matrix:
        include:
          - id: api
            image_name: api
            dockerfile: Dockerfile
            context: .
            tag_prefix: api/v
          - id: worker
            image_name: worker
            dockerfile: docker/worker/Dockerfile
            context: docker/worker
            tag_prefix: worker/v
    permissions:
      contents: write
      packages: write
    uses: synkube/actions/.github/workflows/docker-build-push.yaml@<sha>
    with:
      image_name: ${{ matrix.image_name }}
      dockerfile: ${{ matrix.dockerfile }}
      context: ${{ matrix.context }}
      tag_prefix: ${{ matrix.tag_prefix }}
    secrets: inherit

  deploy-api:
    needs: docker
    if: github.ref == 'refs/heads/main'
    uses: synkube/actions/.github/workflows/deploy.yaml@<sha>
    with:
      tag_prefix: api/v
      managed_key: api.tag
      values_path: values/.../my-service.yaml
      github_environment: prod
    secrets: inherit
```

Repos with path-filtered builds (e.g. jwt-exchange) should build a filtered `matrix.include` JSON in an upstream job rather than encoding dockerfile paths in `with:` expressions.
