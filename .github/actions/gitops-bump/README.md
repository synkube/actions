# gitops-bump

Update a Helm values file line marked `# github-workflow-managed:<key>`, then **push** to a branch or **open a pull request** on the GitOps repo.

Typically used via the reusable **Deploy** workflow (`.github/workflows/deploy.yaml`), which exchanges OIDC for a short-lived installation token on the GitOps repo first.

## Delivery modes

| `delivery` | Behavior | Token needs |
| --- | --- | --- |
| `push` (default) | Commit and push to `branch` (usually `main`) | `contents: write` |
| `pull_request` | Commit on `gitops/bump/<key>/<version>`, push head branch, open/reuse PR into `branch` | `contents: write`, `pull_requests: write` |

Use **`pull_request`** when `main` (or your GitOps default branch) is protected — required reviewers, no direct pushes. The bot can still open PRs; it cannot merge until a human (or a separate merger workflow) approves.

## Managed value marker

Add a trailing marker on the line to update:

```yaml
image:
  repository: ghcr.io/synkube/jwt-exchange/service
  tag: "0.0.6" # github-workflow-managed:service.tag
```

Supported shapes on the same line as the marker:

| Shape | Example |
| --- | --- |
| Quoted `tag:` | `tag: "1.2.3" # github-workflow-managed:service.tag` |
| Inline image tag | `image: ghcr.io/org/repo/name:1.2.3 # github-workflow-managed:opa.image` |

## Usage (composite, direct push)

```yaml
- name: Exchange for GitOps repo
  id: token
  uses: synkube/actions/.github/actions/jwt-exchange@<sha>
  with:
    jwt_exchange_url: https://jwt-exchange.synkube.com
    target_repo: synkube/lite-do-argo-apps
    requested_permissions: '{"contents":"write","metadata":"read"}'

- name: Bump values
  uses: synkube/actions/.github/actions/gitops-bump@<sha>
  with:
    token: ${{ steps.token.outputs.token }}
    gitops_repo: synkube/lite-do-argo-apps
    values_path: values/claw/prod/workloads/jwt-exchange.yaml
    managed_key: service.tag
    version: "0.0.7"
```

## Usage (composite, pull request)

```yaml
    requested_permissions: '{"contents":"write","pull_requests":"write","metadata":"read"}'
    # ...
    delivery: pull_request
    branch: main
```

## Usage (reusable Deploy workflow)

Direct push (default):

```yaml
jobs:
  deploy-service:
    uses: synkube/actions/.github/workflows/deploy.yaml@<sha>
    with:
      tag_prefix: service/v
      values_path: values/claw/prod/workloads/jwt-exchange.yaml
      managed_key: service.tag
      gitops_repo: synkube/lite-do-argo-apps
      github_environment: prod
```

Pull request for human review:

```yaml
    with:
      delivery: pull_request
      gitops_branch: main
      # requested_permissions auto-includes pull_requests:write when delivery=pull_request
```

Requires a jwt-exchange **explicit policy** for the caller repo → `synkube/lite-do-argo-apps` with `contents: write` (and `pull_requests: write` when using PR mode).

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `token` | yes | — | GitHub token on `gitops_repo` |
| `gitops_repo` | yes | — | `owner/repo` |
| `values_path` | yes | — | File path inside that repo |
| `managed_key` | yes | — | Suffix on `# github-workflow-managed:<key>` |
| `version` | yes | — | New value to write |
| `delivery` | no | `push` | `push` or `pull_request` |
| `branch` | no | `main` | Push target or PR base branch |
| `pr_branch_prefix` | no | `gitops/bump` | PR head branch prefix |
| `pr_title` | no | auto | PR title |
| `pr_body` | no | auto | PR body |
| `close_superseded_prs` | no | `true` | Close older open bump PRs for the same `managed_key` |
| `commit_message` | no | auto | Commit message |
| `git_user_name` | no | `github-actions[bot]` | Git author |
| `git_user_email` | no | bot noreply | Git email |
| `source_repo` | no | `${{ github.repository }}` | Shown in default messages |

## Outputs

| Output | Description |
| --- | --- |
| `changed` | `true` when the file was updated and delivered |
| `commit_sha` | Commit on GitOps head branch when `changed=true` |
| `pr_branch` | Head branch when `delivery=pull_request` |
| `pr_url` | PR URL when `delivery=pull_request` |
| `pr_number` | PR number when `delivery=pull_request` |
| `closed_pr_numbers` | Comma-separated PR numbers closed as superseded (same `managed_key`, older version branches) |

### Superseded PR cleanup

With `delivery: pull_request` and `close_superseded_prs: true` (default), after opening/reusing the current PR the action closes **other open PRs** whose head branch matches:

`gitops/bump/<managed-key>/<older-version>`

Same `managed_key` only — e.g. closing `service.tag` bumps does not touch `opa.image` PRs. Stale PRs get a comment referencing the new PR and their head branch is deleted.

Set `close_superseded_prs: false` to keep older bump PRs open.

## Local script check

```bash
bash -n .github/actions/gitops-bump/update-managed-values.sh
bash -n .github/actions/gitops-bump/submit-gitops-change.sh
./.github/actions/gitops-bump/update-managed-values.sh /tmp/values.yaml service.tag 9.9.9
./.github/actions/gitops-bump/submit-gitops-change.sh --print-pr-branch gitops/bump service.tag 0.0.9
# -> gitops/bump/service-tag/0.0.9
```
