# synkube/actions

Reusable GitHub Actions for the synkube organization.

## Actions

| Path | Description |
| --- | --- |
| [.github/actions/kics-github-action](.github/actions/kics-github-action) | [KICS](https://kics.io/) static analysis for Infrastructure as Code (fork of [Checkmarx/kics-github-action](https://github.com/Checkmarx/kics-github-action) with a digest-pinned KICS engine image) |
| [.github/actions/trivy-fs](.github/actions/trivy-fs) | Trivy filesystem (dependency) scan with optional SARIF upload to GHAS |
| [.github/actions/trivy-image](.github/actions/trivy-image) | Trivy container image scan with optional SARIF upload to GHAS |

## Workflows

| Path | Description |
| --- | --- |
| [.github/workflows/docker-build-push.yaml](.github/workflows/docker-build-push.yaml) | Reusable Docker build — GHCR push on main, semver git tag, optional Trivy image scan (see caller permissions below) |
| [.github/workflows/kics-scan.yaml](.github/workflows/kics-scan.yaml) | Reusable KICS IaC scan (digest-pinned engine, optional SARIF) |
| [.github/workflows/argocd-diff-workload.yaml](.github/workflows/argocd-diff-workload.yaml) | Reusable ArgoCD diff preview for co-located workload repos (`apps/` + `charts/` + `workloads/`) |
| [.github/workflows/sha-tag.yaml](.github/workflows/sha-tag.yaml) | Resolve composite SHA suffix tag from latest git tag |

## Usage

Org convention: **`uses`** is pinned to the **full commit SHA** of this repo; the **release tag** (e.g. **`v1.0.0`**) appears **only in the trailing comment** so reviewers know which release line you intend.

```yaml
- uses: synkube/actions/.github/actions/kics-github-action@9f425ac79ec75ce388b4e27528784a095a272584 # v1.0.0
  with:
    path: terraform
```

When you cut a new release, bump the SHA to the commit that tag points at and update the comment (e.g. `# v1.0.1`).

KICS reusable workflow (path filters / `CI_G_KICS_ENABLED` stay in the caller):

```yaml
jobs:
  kics:
    if: vars.CI_G_KICS_ENABLED != 'false'
    uses: synkube/actions/.github/workflows/kics-scan.yaml@<sha>
```

Reusable workflows that call composites in this repo (`docker-build-push`, `argocd-diff-workload`, `kics-scan`) must pin those composites to the **same commit SHA** callers use for the workflow `uses:` line. GitHub does not allow `${{ github.workflow_sha }}` for cross-repo `uses:` (that is the caller workflow, not `synkube/actions`). Before tagging a release, run `scripts/sync-internal-action-refs.sh` and commit any diff so internal composite refs match `HEAD`.

### Caller job permissions (reusable workflows)

Nested workflows cannot escalate `GITHUB_TOKEN` beyond what the **calling job** grants. Set `permissions` on the calling job to the scopes in the table. Unlisted scopes default to `none`.

| Called workflow | Grant on the calling job |
| --- | --- |
| `docker-build-push.yaml` | `contents: write`, `packages: write` |

Pass `secrets.extra_checkout_token` when `extra_repository` is a private repository.

Example (docker job):

```yaml
  docker-api:
    permissions:
      contents: write
      packages: write
    uses: synkube/actions/.github/workflows/docker-build-push.yaml@<sha>
    secrets: inherit
```

ArgoCD diff for enterprise workload repos (co-located `apps/`). Pin **`uses`** to a commit SHA of this repo. Layout (`single` vs `multi`) is inferred from the `apps/` tree.

```yaml
jobs:
  argocd-diff:
    if: vars.CI_G_ARGOCD_DIFF_ENABLED != 'false'
    permissions:
      contents: read
      pull-requests: write
    uses: synkube/actions/.github/workflows/argocd-diff-workload.yaml@<sha>
```

**Credentials:** `GITHUB_TOKEN` only (automatic). No secrets in this public repo.

No AWS or cluster credentials are required; rendering runs in the `argocd-diff-preview` container locally in CI.

### Multiple images (one job per image)

Each image gets its own matrix row; GitHub runs one reusable-workflow job per row in parallel.

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
```

Repos with path-filtered builds should build a filtered `matrix.include` JSON in an upstream job rather than encoding dockerfile paths in `with:` expressions.
