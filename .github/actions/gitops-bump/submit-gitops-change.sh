#!/usr/bin/env bash
# Commit a staged GitOps values change and deliver via direct push or pull request.
set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

is_recoverable_push_rejection() {
  local err="$1"
  grep -qiE 'non-fast-forward|fetch first|rejected|failed to push some refs' <<< "${err}"
}

reapply_managed_bump() {
  "${SCRIPT_DIR}/update-managed-values.sh" \
    "${VALUES_PATH}" \
    "${MANAGED_KEY}" \
    "${VERSION}"
}

push_to_branch_with_retry() {
  local max_attempts="${PUSH_RETRY_MAX:-5}"
  local attempt=1
  local push_err=""

  git commit -m "${COMMIT_MESSAGE}"

  while (( attempt <= max_attempts )); do
    push_err=""
    if push_err="$(git push origin "HEAD:${BRANCH}" 2>&1)"; then
      echo "changed=true" >> "${GITHUB_OUTPUT}"
      echo "commit_sha=$(git rev-parse HEAD)" >> "${GITHUB_OUTPUT}"
      return 0
    fi

    if ! is_recoverable_push_rejection "${push_err}"; then
      echo "${push_err}" >&2
      fail "git push to ${BRANCH} failed (non-recoverable)"
    fi

    echo "::warning::Push to ${BRANCH} rejected (attempt ${attempt}/${max_attempts}); syncing with origin/${BRANCH}..." >&2
    echo "${push_err}" >&2

    git fetch --no-tags origin "${BRANCH}" || fail "git fetch origin ${BRANCH} failed during push retry"

    if git rebase "origin/${BRANCH}"; then
      attempt=$((attempt + 1))
      sleep "${attempt}"
      continue
    fi

    echo "::warning::Rebase conflict on ${BRANCH}; resetting to origin/${BRANCH} and re-applying bump" >&2
    git rebase --abort 2>/dev/null || true
    git reset --hard "origin/${BRANCH}"
    reapply_managed_bump
    git add "${VALUES_PATH}"
    if git diff --staged --quiet; then
      echo "Remote ${BRANCH} already has ${MANAGED_KEY}=${VERSION}; nothing to push"
      echo "changed=false" >> "${GITHUB_OUTPUT}"
      return 0
    fi
    git commit -m "${COMMIT_MESSAGE}"
    attempt=$((attempt + 1))
    sleep "${attempt}"
  done

  fail "git push to ${BRANCH} failed after ${max_attempts} attempts (concurrent GitOps updates?)"
}

sanitize_managed_key() {
  local key="$1"
  local safe_key="${key//./-}"
  safe_key="${safe_key//\//-}"
  safe_key="$(printf '%s' "${safe_key}" | tr -cd '[:alnum:]._-' | sed 's/--*/-/g')"
  printf '%s' "${safe_key}"
}

print_pr_branch() {
  local prefix="$1"
  local key="$2"
  local version="$3"
  printf '%s\n' "${prefix}/$(sanitize_managed_key "${key}")/${version}"
}

print_pr_family() {
  local prefix="$1"
  local key="$2"
  printf '%s\n' "${prefix}/$(sanitize_managed_key "${key}")"
}

if [[ "${1:-}" == "--print-pr-branch" ]]; then
  print_pr_branch "${2:?prefix}" "${3:?managed_key}" "${4:?version}"
  exit 0
fi

if [[ "${1:-}" == "--print-pr-family" ]]; then
  print_pr_family "${2:?prefix}" "${3:?managed_key}"
  exit 0
fi

DELIVERY="${DELIVERY:-push}"
VALUES_PATH="${VALUES_PATH:-}"
MANAGED_KEY="${MANAGED_KEY:-}"
VERSION="${VERSION:-}"
BRANCH="${BRANCH:-main}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-}"
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
SOURCE_REPO="${SOURCE_REPO:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITOPS_REPO="${GITOPS_REPO:-}"
PR_BRANCH_PREFIX="${PR_BRANCH_PREFIX:-gitops/bump}"
PR_TITLE="${PR_TITLE:-}"
PR_BODY="${PR_BODY:-}"
CLOSE_SUPERSEDED_PRS="${CLOSE_SUPERSEDED_PRS:-true}"
GH_TOKEN="${GH_TOKEN:-}"

[[ -n "${VALUES_PATH}" && -f "${VALUES_PATH}" ]] || fail "VALUES_PATH file not found"
[[ -n "${MANAGED_KEY}" ]] || fail "MANAGED_KEY is required"
[[ -n "${VERSION}" ]] || fail "VERSION is required"
[[ "${DELIVERY}" == "push" || "${DELIVERY}" == "pull_request" ]] || fail "DELIVERY must be push or pull_request"

if [[ "${DELIVERY}" == "pull_request" ]]; then
  [[ -n "${GH_TOKEN}" ]] || fail "GH_TOKEN is required for pull_request delivery"
  command -v gh >/dev/null 2>&1 || fail "gh CLI is required for pull_request delivery"
  command -v jq >/dev/null 2>&1 || fail "jq is required for pull_request delivery"
fi

git config user.name "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"

git add "${VALUES_PATH}"
if git diff --staged --quiet; then
  echo "No staged changes in ${VALUES_PATH}"
  echo "changed=false" >> "${GITHUB_OUTPUT}"
  exit 0
fi

if [[ -z "${COMMIT_MESSAGE}" ]]; then
  src="${SOURCE_REPO:-${GITHUB_REPOSITORY}}"
  COMMIT_MESSAGE="chore(gitops): bump ${MANAGED_KEY} to ${VERSION} (${src})"
fi

if [[ "${DELIVERY}" == "push" ]]; then
  push_to_branch_with_retry
  exit 0
fi

PR_BRANCH="$(print_pr_branch "${PR_BRANCH_PREFIX}" "${MANAGED_KEY}" "${VERSION}")"
PR_FAMILY="$(print_pr_family "${PR_BRANCH_PREFIX}" "${MANAGED_KEY}")"
git checkout -B "${PR_BRANCH}"
git commit -m "${COMMIT_MESSAGE}"

git fetch --no-tags origin "${PR_BRANCH}" 2>/dev/null || true
if git rev-parse --verify --quiet "refs/remotes/origin/${PR_BRANCH}" >/dev/null; then
  git push --force-with-lease=origin/"${PR_BRANCH}" -u origin "${PR_BRANCH}"
else
  git push -u origin "${PR_BRANCH}"
fi

if [[ -z "${PR_TITLE}" ]]; then
  PR_TITLE="${COMMIT_MESSAGE}"
fi
if [[ -z "${PR_BODY}" ]]; then
  src="${SOURCE_REPO:-${GITHUB_REPOSITORY}}"
  PR_BODY="Automated GitOps bump from **${src}**.

When **${BRANCH}** is protected (PR required, no direct pushes), merge this PR to deploy via ArgoCD."
fi

repo_args=()
if [[ -n "${GITOPS_REPO}" ]]; then
  repo_args=(--repo "${GITOPS_REPO}")
fi

if gh pr view "${PR_BRANCH}" "${repo_args[@]}" --json url,number,state >/tmp/gh-pr-view.json 2>/dev/null \
  && [[ "$(jq -r .state /tmp/gh-pr-view.json)" == "OPEN" ]]; then
  pr_url="$(jq -r .url /tmp/gh-pr-view.json)"
  pr_number="$(jq -r .number /tmp/gh-pr-view.json)"
  echo "Reusing open pull request #${pr_number}"
else
  pr_url="$(gh pr create "${repo_args[@]}" --base "${BRANCH}" --head "${PR_BRANCH}" --title "${PR_TITLE}" --body "${PR_BODY}")"
  pr_number="$(gh pr view "${PR_BRANCH}" "${repo_args[@]}" --json number --jq .number)"
fi

closed_pr_numbers=()
if [[ "${CLOSE_SUPERSEDED_PRS}" == "true" || "${CLOSE_SUPERSEDED_PRS}" == "1" ]]; then
  family_prefix="${PR_FAMILY}/"
  mapfile -t stale_numbers < <(
    gh pr list "${repo_args[@]}" --state open --base "${BRANCH}" --limit 200 --json number,headRefName \
      | jq -r --arg family "${family_prefix}" --arg keep "${PR_BRANCH}" \
        '.[] | select(.headRefName | startswith($family)) | select(.headRefName != $keep) | .number | tostring'
  )

  for stale in "${stale_numbers[@]}"; do
    [[ -z "${stale}" ]] && continue
    close_comment="Superseded by #${pr_number} (${MANAGED_KEY} → ${VERSION})."
    if gh pr close "${stale}" "${repo_args[@]}" --comment "${close_comment}" --delete-branch; then
      echo "Closed superseded pull request #${stale}"
      closed_pr_numbers+=("${stale}")
    else
      echo "::warning::Failed to close superseded pull request #${stale}"
    fi
  done
fi

closed_csv="$(IFS=,; echo "${closed_pr_numbers[*]-}")"

{
  echo "changed=true"
  echo "commit_sha=$(git rev-parse HEAD)"
  echo "pr_branch=${PR_BRANCH}"
  echo "pr_url=${pr_url}"
  echo "pr_number=${pr_number}"
  echo "closed_pr_numbers=${closed_csv}"
} >> "${GITHUB_OUTPUT}"
