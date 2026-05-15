# synkube/actions

Reusable GitHub Actions for the synkube organization.

## Actions

| Path | Description |
| --- | --- |
| [.github/actions/kics-github-action](.github/actions/kics-github-action) | [KICS](https://kics.io/) static analysis for Infrastructure as Code (fork of [Checkmarx/kics-github-action](https://github.com/Checkmarx/kics-github-action) with a digest-pinned KICS engine image) |

## Usage

Org convention: **`uses`** is pinned to the **full commit SHA** of this repo; the **release tag** (e.g. **`v1.0.0`**) appears **only in the trailing comment** so reviewers know which release line you intend.

```yaml
- uses: synkube/actions/.github/actions/kics-github-action@9f425ac79ec75ce388b4e27528784a095a272584 # v1.0.0
  with:
    path: terraform
```

When you cut a new release, bump the SHA to the commit that tag points at and update the comment (e.g. `# v1.0.1`).
