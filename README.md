# synkube/actions

Reusable GitHub Actions for the synkube organization.

## Actions

| Path | Description |
| --- | --- |
| [.github/actions/kics-github-action](.github/actions/kics-github-action) | [KICS](https://kics.io/) static analysis for Infrastructure as Code (fork of [Checkmarx/kics-github-action](https://github.com/Checkmarx/kics-github-action) with a digest-pinned KICS engine image) |

## Usage

Reference an action with the repo path and a git ref (branch, tag, or full commit SHA), for example:

```yaml
- uses: synkube/actions/.github/actions/kics-github-action@main
  with:
    path: terraform
```

Prefer pinning the repository at a full commit SHA for maximum reproducibility, consistent with the rest of your supply-chain hardening.
