#!/usr/bin/env bash
# Point synkube/actions composite refs inside reusable workflows at the current
# commit (release discipline). Run from repo root before tagging a release.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

sha="$(git rev-parse HEAD)"
shopt -s nullglob
files=(.github/workflows/*.yaml)
[[ ${#files[@]} -gt 0 ]] || { echo "no workflow files"; exit 1; }

perl -pi -e "
  s#(synkube/actions/\\.github/actions/[a-z0-9-]+@)[0-9a-f]{40}#\${1}${sha}#g
" "${files[@]}"

echo "Set internal composite refs to ${sha}"
grep -E 'synkube/actions/\.github/actions/[a-z0-9-]+@' .github/workflows/*.yaml || true
