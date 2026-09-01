#!/usr/bin/env bash
# Map PR file changes to co-located Application manifest paths under apps/.
set -euo pipefail

: "${CHANGED_FILES:?}"
: "${APPS_PATH:=apps}"
: "${WORKLOADS_PATH:=workloads}"
: "${CHARTS_PATH:=charts}"
: "${LAYOUT:=auto}"

AFFECTED=""

add_app() {
  local path="$1"
  [[ -z "$path" ]] && return
  if [[ -f "$path" ]]; then
    AFFECTED="${AFFECTED}${path}"$'\n'
  fi
}

add_all_single_apps() {
  while IFS= read -r f; do
    add_app "$f"
  done < <(find "${APPS_PATH}" -mindepth 2 -maxdepth 2 -name '*.yaml' -o -name '*.yml' 2>/dev/null | sort -u)
}

add_all_multi_apps() {
  while IFS= read -r f; do
    add_app "$f"
  done < <(find "${APPS_PATH}" -mindepth 3 -maxdepth 3 \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort -u)
}

resolve_layout() {
  if [[ "$LAYOUT" != "auto" ]]; then
    echo "$LAYOUT"
    return
  fi
  if find "${APPS_PATH}" -mindepth 3 -maxdepth 3 \( -name '*.yaml' -o -name '*.yml' \) -print -quit 2>/dev/null | grep -q .; then
    echo "multi"
  else
    echo "single"
  fi
}

LAYOUT_RESOLVED="$(resolve_layout)"

for file in ${CHANGED_FILES}; do
  case "$file" in
    "${APPS_PATH}"/*/*/*.*)
      add_app "$file"
      ;;
    "${APPS_PATH}"/*/*.*)
      add_app "$file"
      ;;
    "${WORKLOADS_PATH}/_base.yaml"|"${WORKLOADS_PATH}/_base.yml")
      if [[ "$LAYOUT_RESOLVED" == "multi" ]]; then
        add_all_multi_apps
      else
        add_all_single_apps
      fi
      ;;
    "${WORKLOADS_PATH}/_base"/*.*)
      comp="$(basename "$file")"
      comp="${comp%.*}"
      while IFS= read -r f; do
        add_app "$f"
      done < <(find "${APPS_PATH}" -name "${comp}.yaml" -o -name "${comp}.yml" 2>/dev/null)
      ;;
    "${WORKLOADS_PATH}"/*/*/*.*)
      env="$(echo "$file" | cut -d/ -f2)"
      region="$(echo "$file" | cut -d/ -f3)"
      comp="$(basename "$file")"
      comp="${comp%.*}"
      add_app "${APPS_PATH}/${env}/${region}/${comp}.yaml"
      add_app "${APPS_PATH}/${env}/${region}/${comp}.yml"
      ;;
    "${WORKLOADS_PATH}"/*/*.*)
      env="$(echo "$file" | cut -d/ -f2)"
      region_file="$(echo "$file" | cut -d/ -f3)"
      region="${region_file%.*}"
      add_app "${APPS_PATH}/${env}/${region}.yaml"
      add_app "${APPS_PATH}/${env}/${region}.yml"
      ;;
    "${CHARTS_PATH}/default"|"${CHARTS_PATH}/default"/*)
      add_all_single_apps
      ;;
    "${CHARTS_PATH}"/*/*)
      comp="$(echo "$file" | cut -d/ -f2)"
      while IFS= read -r f; do
        add_app "$f"
      done < <(find "${APPS_PATH}" -name "${comp}.yaml" -o -name "${comp}.yml" 2>/dev/null)
      ;;
    "${CHARTS_PATH}"/*)
      comp="$(echo "$file" | cut -d/ -f2)"
      while IFS= read -r f; do
        add_app "$f"
      done < <(find "${APPS_PATH}" -name "${comp}.yaml" -o -name "${comp}.yml" 2>/dev/null)
      ;;
  esac
done

UNIQUE=$(printf '%s' "$AFFECTED" | sort -u | grep -v '^$' || true)

if [[ -z "$UNIQUE" ]]; then
  echo "has_changes=false" >> "${GITHUB_OUTPUT}"
  echo 'matrix={"include":[]}' >> "${GITHUB_OUTPUT}"
  echo 'changed_files_by_app={}' >> "${GITHUB_OUTPUT}"
  exit 0
fi

MATRIX_JSON='{"include":[]}'
CHANGED_BY_APP='{}'

while IFS= read -r app_path; do
  [[ -z "$app_path" ]] && continue
  app_key="$(echo "$app_path" | sed "s#^${APPS_PATH}/##" | tr '/' '-' | sed 's/\.[^.]*$//')"
  MATRIX_JSON="$(echo "$MATRIX_JSON" | jq -c --arg k "$app_key" --arg p "$app_path" '.include += [{app_key: $k, app_path: $p}]')"

  matched_files=$(printf '%s\n' ${CHANGED_FILES} | jq -R -s -c --arg app "$app_path" '
    split("\n") | map(select(length > 0)) |
    map(select(
      . == $app or
      startswith("workloads/") or
      startswith("charts/")
    ))
  ')
  CHANGED_BY_APP="$(echo "$CHANGED_BY_APP" | jq -c --arg k "$app_key" --argjson v "$matched_files" '. + {($k): $v}')"
done <<< "$UNIQUE"

echo "has_changes=true" >> "${GITHUB_OUTPUT}"
echo "matrix=$(echo "$MATRIX_JSON" | jq -c .)" >> "${GITHUB_OUTPUT}"
echo "changed_files_by_app=$(echo "$CHANGED_BY_APP" | jq -c .)" >> "${GITHUB_OUTPUT}"

echo "Detected apps:" >&2
echo "$UNIQUE" >&2
