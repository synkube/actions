#!/usr/bin/env bash
# Exchange GitHub Actions OIDC JWT for a credential via synkube jwt-exchange (v2 API).
#
# Source of truth for the contract:
#   POST /api/v2/exchange/token
#   - body: {exchange_profile?, subject_token, resource:{type:"github_repository", id:"owner/repo"},
#            requested:{github_permissions: <object<read|write>>}}
#   - 2xx (installation profile):
#       {exchange_profile, issued_token_type:"urn:github:installation_access_token",
#        token, expires_at, permissions}
#   - 4xx: {status:"fail",  message}   (validation / policy / auth — deterministic, DO NOT retry)
#   - 5xx: {status:"error", message}   (upstream/internal — may be transient, retry once)
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-${GITHUB_REPOSITORY:-}}"
AUDIENCE="${AUDIENCE:-api://jwt-exchange}"
# Note: `${VAR-default}` (no colon) preserves an explicit empty string from the
# caller, which means "omit exchange_profile from the body and use the service
# default" — distinct from the action input default `github_actions_to_installation`.
EXCHANGE_PROFILE="${EXCHANGE_PROFILE-github_actions_to_installation}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
MAX_TIME="${MAX_TIME:-30}"
RETRY_DELAY="${RETRY_DELAY:-3}"
INSTALLATION_REPOSITORY_SCOPE="${INSTALLATION_REPOSITORY_SCOPE:-target}"

fail() {
  echo "::error::$1"
  exit 1
}

[[ -n "${JWT_EXCHANGE_URL:-}" ]] || fail "jwt_exchange_url input is required"
[[ -n "${TARGET_REPO:-}" ]] || fail "target_repo input is required"
[[ -n "${REQUESTED_PERMISSIONS:-}" ]] || fail "requested_permissions input is required"
[[ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]] \
  || fail "OIDC env not set — caller job needs 'permissions: { id-token: write }'"

# Mirror the v2 schema so the caller gets a fast, local error instead of a 400 round-trip.
[[ "${TARGET_REPO}" =~ ^[^/]+/[^/]+$ ]] \
  || fail "target_repo '${TARGET_REPO}' is not in 'owner/repo' format"

if ! jq -e 'type == "object" and (length > 0)' >/dev/null 2>&1 <<<"${REQUESTED_PERMISSIONS}"; then
  fail "requested_permissions must be a non-empty JSON object, e.g. {\"contents\":\"write\"}"
fi
if ! jq -e 'to_entries | map(.value | IN("read","write")) | all' >/dev/null 2>&1 <<<"${REQUESTED_PERMISSIONS}"; then
  fail "requested_permissions values must each be \"read\" or \"write\""
fi

echo "Requesting OIDC token (audience=${AUDIENCE})"
OIDC_TOKEN="$(
  curl -sSf --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${MAX_TIME}" \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUDIENCE}" |
    jq -r '.value // empty'
)" || fail "Failed to obtain GitHub OIDC token from runner endpoint"

[[ -n "${OIDC_TOKEN}" && "${OIDC_TOKEN}" != "null" ]] \
  || fail "OIDC endpoint returned an empty token value"

echo "::add-mask::${OIDC_TOKEN}"

[[ "${INSTALLATION_REPOSITORY_SCOPE}" == "target" || "${INSTALLATION_REPOSITORY_SCOPE}" == "all" ]] \
  || fail "installation_repository_scope must be 'target' or 'all'"

EXCHANGE_URL="${JWT_EXCHANGE_URL%/}/api/v2/exchange/token"
PAYLOAD="$(
  jq -cn \
    --arg subject_token "${OIDC_TOKEN}" \
    --arg target_repo "${TARGET_REPO}" \
    --arg exchange_profile "${EXCHANGE_PROFILE}" \
    --arg installation_repository_scope "${INSTALLATION_REPOSITORY_SCOPE}" \
    --argjson github_permissions "${REQUESTED_PERMISSIONS}" \
    '{
       subject_token: $subject_token,
       resource: {type: "github_repository", id: $target_repo},
       requested: (
         {github_permissions: $github_permissions}
         + (if $installation_repository_scope == "all"
            then {installation_repository_scope: "all"}
            else {})
       )
     }
     + (if $exchange_profile == "" then {} else {exchange_profile: $exchange_profile} end)'
)"

enrich_failure_message() {
  local detail="${1}"
  if [[ "${HTTP_CODE:-}" == "404" ]]; then
    if [[ -z "${detail}" || "${detail}" == "Not Found" || "${detail}" == *"GitHub resource not found"* ]]; then
      detail="GitHub App is not installed on ${TARGET_REPO}. Install the jwt-exchange GitHub App on the target repository or organization."
    elif [[ "${detail}" != *"not installed"* ]]; then
      detail="${detail} GitHub App may not be installed on ${TARGET_REPO}."
    fi
  elif [[ "${HTTP_CODE:-}" == "403" && -n "${POLICY_DOCS_URL:-}" && "${detail}" != *"${POLICY_DOCS_URL}"* ]]; then
    detail="${detail} Review policy at ${POLICY_DOCS_URL}."
  fi
  printf '%s' "${detail}"
}

report_failure() {
  local detail
  detail="$(enrich_failure_message "${1}")"
  echo "::error::jwt-exchange failed: ${detail} (source ${SOURCE_REPO:-unknown} → target ${TARGET_REPO}, HTTP ${HTTP_CODE:-?}, profile ${EXCHANGE_PROFILE:-default})"
}

attempt=0
HTTP_CODE=""
RESPONSE=""
while :; do
  attempt=$((attempt + 1))
  echo "Exchanging token for ${TARGET_REPO} via ${EXCHANGE_URL} (attempt ${attempt}/${MAX_ATTEMPTS})"

  set +e
  RAW="$(
    curl -sS --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${MAX_TIME}" \
      -w $'\n%{http_code}' \
      -X POST "${EXCHANGE_URL}" \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}"
  )"
  curl_exit=$?
  set -e

  if [[ ${curl_exit} -ne 0 ]]; then
    if [[ ${attempt} -lt ${MAX_ATTEMPTS} ]]; then
      echo "::warning::curl exit=${curl_exit} (network/timeout); retrying in ${RETRY_DELAY}s"
      sleep "${RETRY_DELAY}"
      continue
    fi
    fail "jwt-exchange request failed: curl exit=${curl_exit} (network/timeout) after ${attempt} attempts"
  fi

  HTTP_CODE="$(tail -n1 <<<"${RAW}")"
  RESPONSE="$(sed '$d' <<<"${RAW}")"

  if [[ ! "${HTTP_CODE}" =~ ^[0-9]+$ ]]; then
    fail "jwt-exchange request failed: no HTTP status from ${EXCHANGE_URL}"
  fi

  # Retry only transient 5xx; 4xx are deterministic (policy/validation/auth).
  if [[ "${HTTP_CODE}" =~ ^5 ]] && [[ ${attempt} -lt ${MAX_ATTEMPTS} ]]; then
    echo "::warning::HTTP ${HTTP_CODE} from jwt-exchange; retrying in ${RETRY_DELAY}s"
    sleep "${RETRY_DELAY}"
    continue
  fi
  break
done

if ! jq -e . >/dev/null 2>&1 <<<"${RESPONSE}"; then
  report_failure "non-JSON response body (first 200 chars): $(printf '%s' "${RESPONSE}" | head -c 200)"
  exit 1
fi

STATUS="$(jq -r '.status // empty' <<<"${RESPONSE}")"
MESSAGE="$(jq -r '.message // empty' <<<"${RESPONSE}")"

if [[ ! "${HTTP_CODE}" =~ ^2 ]] || [[ "${STATUS}" == "fail" || "${STATUS}" == "error" ]]; then
  report_failure "${MESSAGE:-HTTP ${HTTP_CODE}}"
  exit 1
fi

TOKEN="$(jq -r '.token // empty' <<<"${RESPONSE}")"
if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
  report_failure "response missing installation token (expected token on HTTP 2xx for installation profile)"
  exit 1
fi

echo "::add-mask::${TOKEN}"

PERMISSIONS="$(jq -c '.permissions // {}' <<<"${RESPONSE}")"
EXPIRES_AT="$(jq -r '.expires_at // empty' <<<"${RESPONSE}")"
ISSUED_TOKEN_TYPE="$(jq -r '.issued_token_type // empty' <<<"${RESPONSE}")"
RESPONSE_PROFILE="$(jq -r '.exchange_profile // empty' <<<"${RESPONSE}")"

echo "Permissions granted:"
jq . <<<"${PERMISSIONS}"

{
  echo "token=${TOKEN}"
  echo "permissions=${PERMISSIONS}"
  echo "expires_at=${EXPIRES_AT}"
  echo "issued_token_type=${ISSUED_TOKEN_TYPE}"
  echo "exchange_profile=${RESPONSE_PROFILE}"
} >>"${GITHUB_OUTPUT}"
