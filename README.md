# synkube/actions

Reusable GitHub Actions for the synkube organization.

## Actions

| Path | Description |
| --- | --- |
| [.github/actions/jwt-exchange](.github/actions/jwt-exchange) | Exchange GitHub Actions OIDC for a short-lived GitHub App installation token via [synkube/jwt-exchange](https://github.com/synkube/jwt-exchange) (`/api/v2/exchange/token`, bash composite) |
| [.github/actions/kics-github-action](.github/actions/kics-github-action) | [KICS](https://kics.io/) static analysis for Infrastructure as Code (fork of [Checkmarx/kics-github-action](https://github.com/Checkmarx/kics-github-action) with a digest-pinned KICS engine image) |
| [.github/actions/trivy-fs](.github/actions/trivy-fs) | Trivy filesystem (dependency) scan with optional SARIF upload to GHAS |
| [.github/actions/trivy-image](.github/actions/trivy-image) | Trivy container image scan with optional SARIF upload to GHAS |

## Usage

Org convention: **`uses`** is pinned to the **full commit SHA** of this repo; the **release tag** (e.g. **`v1.0.0`**) appears **only in the trailing comment** so reviewers know which release line you intend.

```yaml
- uses: synkube/actions/.github/actions/kics-github-action@9f425ac79ec75ce388b4e27528784a095a272584 # v1.0.0
  with:
    path: terraform
```

When you cut a new release, bump the SHA to the commit that tag points at and update the comment (e.g. `# v1.0.1`).
