#!/usr/bin/env bash
# Prepare base-branch/applications and target-branch/applications for argocd-diff-preview.
set -euo pipefail

: "${APP_PATH:?}"
: "${APP_KEY:?}"
: "${BASE_DIR:=base-branch}"
: "${TARGET_DIR:=target-branch}"
: "${TARGET_BRANCH:?}"
: "${BASE_BRANCH:=main}"
: "${REPO_FULL_NAME:?}"
: "${CHANGED_FILES_BY_APP:=\{\}}"

mkdir -p "${BASE_DIR}/applications" "${TARGET_DIR}/applications"

REPO_URL="https://github.com/${REPO_FULL_NAME}"

patch_application() {
  local file="$1"
  local branch="$2"
  local out="$3"
  local count idx source_repo

  cp "$file" "$out"

  if yq -e '.spec | has("sources")' "$out" >/dev/null 2>&1; then
    count="$(yq '.spec.sources | length' "$out")"
    for idx in $(seq 0 $((count - 1))); do
      source_repo="$(yq -r ".spec.sources[$idx].repoURL // \"\"" "$out")"
      if [[ "$source_repo" == *"${REPO_FULL_NAME}"* ]] || [[ "$source_repo" == "$REPO_URL"* ]]; then
        yq -i ".spec.sources[$idx].targetRevision = \"${branch}\"" "$out"
      fi
    done
  else
    yq -i ".spec.source.targetRevision = \"${branch}\"" "$out"
  fi
}

process_applicationset() {
  local doc_file="$1"
  local side="$2"
  local out_dir="$3"
  local changed_files all_elements generators gen_idx gen nested nested_count matrix_result
  local nest_idx nest_gen elements shared_changed affected_elements affected_count template
  local element element_id app_yaml output_name branch base_yaml target_yaml source_count sidx tmpl_source_repo
  local key value escaped_value escaped_key

  changed_files="$(echo "$CHANGED_FILES_BY_APP" | jq -c --arg k "$APP_KEY" '.[$k] // []')"

  all_elements="[]"
  generators="$(yq -o=json '.spec.generators' "$doc_file")"

  for gen_idx in $(echo "$generators" | jq -r 'keys[]'); do
    gen="$(echo "$generators" | jq -c ".[$gen_idx]")"

    if echo "$gen" | jq -e '.list' >/dev/null 2>&1; then
      all_elements="$(echo "$all_elements" | jq -c --argjson new "$(echo "$gen" | jq -c '.list.elements // []')" '. + $new')"
    elif echo "$gen" | jq -e '.matrix' >/dev/null 2>&1; then
      nested="$(echo "$gen" | jq -c '.matrix.generators')"
      nested_count="$(echo "$nested" | jq 'length')"
      matrix_result="[]"
      for nest_idx in $(seq 0 $((nested_count - 1))); do
        nest_gen="$(echo "$nested" | jq -c ".[$nest_idx]")"
        if echo "$nest_gen" | jq -e '.list' >/dev/null 2>&1; then
          elements="$(echo "$nest_gen" | jq -c '.list.elements // []')"
          if [ "$(echo "$elements" | jq 'length')" -gt 0 ] && [ "$(echo "$matrix_result" | jq 'length')" -eq 0 ]; then
            matrix_result="$elements"
          elif [ "$(echo "$elements" | jq 'length')" -gt 0 ]; then
            matrix_result="$(jq -n --argjson a "$matrix_result" --argjson b "$elements" '[ $a[] as $x | $b[] as $y | ($x + $y) ]')"
          fi
        fi
      done
      if [ "$(echo "$matrix_result" | jq 'length')" -gt 0 ]; then
        all_elements="$(echo "$all_elements" | jq -c --argjson new "$matrix_result" '. + $new')"
      fi
    fi
  done

  shared_changed="$(echo "$changed_files" | jq 'map(select(test("^(values|Chart)\\.(yaml|yml)$") or test("^templates/") or test("^charts/"))) | length > 0')"

  if [ "$shared_changed" = "true" ]; then
    affected_elements="$all_elements"
  else
    affected_elements="$(echo "$changed_files" | jq -c --argjson elements "$all_elements" '
      def strip_ext: sub("\\.(yaml|yml)$"; "");
      (map(strip_ext) | unique) as $paths |
      (map(sub(".*/"; "") | strip_ext) | unique) as $bases |
      $elements | map(
        . as $elem |
        ($elem | to_entries | map(.value) | map(select(type == "string")) | map(., strip_ext, sub(".*/"; "")) | unique) as $vals |
        select(any($vals[]; . as $v | ($paths + $bases) | any(. == $v)))
      )
    ')"
  fi

  affected_count="$(echo "$affected_elements" | jq 'length')"
  if [ "$affected_count" -eq 0 ]; then
    echo "No ApplicationSet elements affected for ${APP_KEY} (${side})" >&2
    return 0
  fi

  template="$(yq -o=json '.spec.template' "$doc_file")"

  echo "$affected_elements" | jq -c '.[]' | while read -r element; do
    element_id="$(echo "$element" | jq -r 'to_entries | map(select(.value | type == "string" or type == "number")) | sort_by(.key) | map("\(.key)=\(.value|tostring)") | join("-")' | tr '/' '-')"
    if [ -z "$element_id" ]; then
      element_id="$(echo "$element" | md5sum | cut -c1-8)"
    fi
    output_name="${APP_KEY}-${element_id}"

    app_yaml="$(echo "$template" | jq '{
      apiVersion: "argoproj.io/v1alpha1",
      kind: "Application",
      metadata: .metadata,
      spec: .spec
    }')"

    while IFS= read -r key; do
      [ -z "$key" ] && continue
      value="$(echo "$element" | jq -r --arg k "$key" '.[$k] | tostring')"
      escaped_value="$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/[&|]/\\&/g')"
      escaped_key="$(printf '%s' "$key" | sed 's/[.[\*^$()+?{|]/\\&/g')"
      app_yaml="$(printf '%s' "$app_yaml" | sed "s|{{.{{[ ]*${escaped_key}[ ]*}}.}}|${escaped_value}|g")"
      app_yaml="$(printf '%s' "$app_yaml" | sed "s|{{[ ]*${escaped_key}[ ]*}}|${escaped_value}|g")"
    done < <(echo "$element" | jq -r 'to_entries | map(select(.value | type == "string" or type == "number")) | .[].key')

    branch="${BASE_BRANCH}"
    [ "$side" = "target" ] && branch="${TARGET_BRANCH}"

    if echo "$app_yaml" | yq -e '.spec | has("sources")' >/dev/null 2>&1; then
      base_yaml="$(echo "$app_yaml" | yq -P '.')"
      target_yaml="$base_yaml"
      source_count="$(echo "$app_yaml" | yq '.spec.sources | length')"
      for sidx in $(seq 0 $((source_count - 1))); do
        tmpl_source_repo="$(echo "$app_yaml" | yq -r ".spec.sources[$sidx].repoURL // \"\"")"
        if [[ "$tmpl_source_repo" == *"${REPO_FULL_NAME}"* ]] || [[ "$tmpl_source_repo" == "$REPO_URL"* ]]; then
          if [ "$side" = "base" ]; then
            base_yaml="$(echo "$base_yaml" | yq ".spec.sources[$sidx].targetRevision = \"${BASE_BRANCH}\"")"
          else
            target_yaml="$(echo "$target_yaml" | yq ".spec.sources[$sidx].targetRevision = \"${TARGET_BRANCH}\"")"
          fi
        fi
      done
      if [ "$side" = "base" ]; then
        echo "$base_yaml" > "${out_dir}/applications/${output_name}.yaml"
      else
        echo "$target_yaml" > "${out_dir}/applications/${output_name}.yaml"
      fi
    else
      if [ "$side" = "base" ]; then
        echo "$app_yaml" | yq -P ".spec.source.targetRevision = \"${BASE_BRANCH}\"" > "${out_dir}/applications/${output_name}.yaml"
      else
        echo "$app_yaml" | yq -P ".spec.source.targetRevision = \"${TARGET_BRANCH}\"" > "${out_dir}/applications/${output_name}.yaml"
      fi
    fi
  done
}

process_side() {
  local side="$1"
  local src_root="$2"
  local manifest doc_count doc_idx doc_file kind suffix out_name

  manifest="${src_root}/${APP_PATH}"

  if [ ! -f "$manifest" ]; then
    echo "Warning: manifest not found: $manifest" >&2
    return 0
  fi

  doc_count="$(yq 'documentIndex' "$manifest" | wc -l | tr -d ' ')"

  for doc_idx in $(seq 0 $((doc_count - 1))); do
    doc_file="$(mktemp)"
    yq "select(documentIndex == $doc_idx)" "$manifest" > "$doc_file"
    kind="$(yq -r '.kind' "$doc_file")"
    suffix=""
    [ "$doc_count" -gt 1 ] && suffix="-doc${doc_idx}"

    case "$kind" in
      Application)
        out_name="${APP_KEY}${suffix}.yaml"
        if [ "$side" = "base" ]; then
          patch_application "$doc_file" "${BASE_BRANCH}" "${BASE_DIR}/applications/${out_name}"
        else
          patch_application "$doc_file" "${TARGET_BRANCH}" "${TARGET_DIR}/applications/${out_name}"
        fi
        ;;
      ApplicationSet)
        if [ "$side" = "base" ]; then
          process_applicationset "$doc_file" "$side" "$BASE_DIR"
        else
          process_applicationset "$doc_file" "$side" "$TARGET_DIR"
        fi
        ;;
      *)
        echo "Warning: skipping unsupported kind ${kind} in ${manifest}" >&2
        ;;
    esac
    rm -f "$doc_file"
  done
}

process_side base "${BASE_DIR}"
process_side target "${TARGET_DIR}"

echo "Base manifests:" >&2
ls -la "${BASE_DIR}/applications/" 2>/dev/null || echo "(none)" >&2
echo "Target manifests:" >&2
ls -la "${TARGET_DIR}/applications/" 2>/dev/null || echo "(none)" >&2
