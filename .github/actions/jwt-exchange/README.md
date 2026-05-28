# jwt-exchange

Bash composite action: GitHub Actions OIDC → [synkube/jwt-exchange](https://github.com/synkube/jwt-exchange) (`/api/v2/exchange/token`) → short-lived GitHub App installation token.

Mirrors the v2 request schema (`subject_token`, `resource.type=github_repository`, `requested.github_permissions`) and the `status: fail | error` error envelope, so policy denials, validation errors, and transient 5xx are all surfaced cleanly to the workflow log.

## Requirements

Caller job permissions (minimum):

```yaml
permissions:
  id-token: write
  contents: read
```

Plus a policy mapping in [synkube/jwt-exchange/policy/policy.rego](https://github.com/synkube/jwt-exchange/blob/main/policy/policy.rego) authorising **source repo + ref/event** → **target repo + permissions** for your workflow.

## Usage

```yaml
jobs:
  cross-repo:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Exchange OIDC for installation token
        id: token
        uses: synkube/actions/.github/actions/jwt-exchange@<sha> # vX.Y.Z
        with:
          jwt_exchange_url: ${{ vars.JWT_EXCHANGE_URL }} # https://jwt-exchange.synkube.com
          target_repo: synkube/jwt-exchange
          requested_permissions: >-
            {"contents":"read","metadata":"read"}

      - name: Use the token
        env:
          GH_TOKEN: ${{ steps.token.outputs.token }}
        run: |
          gh api repos/synkube/jwt-exchange
          echo "Granted: ${{ steps.token.outputs.permissions }}"
          echo "Expires: ${{ steps.token.outputs.expires_at }}"
```

### Cross-repo checkout

```yaml
- name: Exchange for workload repo
  id: token
  uses: synkube/actions/.github/actions/jwt-exchange@<sha> # vX.Y.Z
  with:
    jwt_exchange_url: ${{ vars.JWT_EXCHANGE_URL }}
    target_repo: ${{ inputs.argocd_workload_repository }}
    requested_permissions: >-
      {"contents":"write","pull_requests":"write"}

- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  with:
    repository: ${{ inputs.argocd_workload_repository }}
    token: ${{ steps.token.outputs.token }}
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `jwt_exchange_url` | yes | — | jwt-exchange base URL (no trailing slash), e.g. `https://jwt-exchange.synkube.com` |
| `target_repo` | yes | — | `owner/repo` to receive the installation token for |
| `requested_permissions` | yes | — | JSON object (`<github permission>: read | write`); sent as `requested.github_permissions` |
| `exchange_profile` | no | `github_actions_to_installation` | Profile id registered in jwt-exchange; pass empty to let the service pick its default |
| `audience` | no | `api://jwt-exchange` | OIDC audience requested from the GitHub id-token endpoint |
| `source_repo` | no | `${{ github.repository }}` | Shown in error messages |
| `policy_docs_url` | no | upstream `policy.rego` link | Shown in policy-denied errors |
| `max_attempts` | no | `2` | Total attempts on **transient** failures (network/timeout, HTTP 5xx). 4xx is never retried. |
| `connect_timeout` | no | `10` | `curl --connect-timeout` seconds |
| `max_time` | no | `30` | `curl --max-time` seconds per attempt |
| `retry_delay` | no | `3` | Seconds between transient retries |

## Outputs

| Output | Description |
| --- | --- |
| `token` | GitHub App installation access token (registered as a log mask) |
| `permissions` | Granted permissions, JSON object |
| `expires_at` | Token expiration timestamp (RFC 3339) |
| `issued_token_type` | URN identifying the issued credential, e.g. `urn:github:installation_access_token` |
| `exchange_profile` | Profile id that produced the token |

## Error handling

Aligned with jwt-exchange `/api/v2/exchange/token`:

| HTTP | `status` | Meaning |
| --- | --- | --- |
| 2xx | (absent) | Success — `token`, `permissions`, `expires_at`, `issued_token_type`, `exchange_profile` |
| 4xx | `fail` | Policy deny, schema validation, auth — surfaced as `::error::`, **not retried** |
| 5xx | `error` | Upstream / internal — retried up to `max_attempts` |

The script uses `curl` **without** `-f` so 4xx/5xx JSON bodies are parsed and the `message` field is surfaced via `::error::` instead of being lost.

## Local script check

```bash
# Validate JSON permissions input (no live exchange without Actions OIDC env):
REQUESTED_PERMISSIONS='{"contents":"read"}' \
  jq -e 'to_entries | map(.value | IN("read","write")) | all' <<<"$REQUESTED_PERMISSIONS"

# Lint:
shellcheck exchange.sh
bash -n exchange.sh
```
