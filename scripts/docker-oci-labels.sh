#!/usr/bin/env bash
# Emit docker buildx --label flags matching docker-build-push OCI metadata.
set -euo pipefail

repo=""
name=""
image_repo=""
version=""
revision=""
licenses="MIT"

usage() {
  echo "usage: $0 --repo synkube/foo --name api --image-repo ghcr.io/synkube/foo/api [--version TAG] [--revision SHA]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --image-repo) image_repo="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --revision) revision="$2"; shift 2 ;;
    --licenses) licenses="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${repo}" && -n "${name}" && -n "${image_repo}" ]] || usage

revision="${revision:-$(git -C "${PWD}" rev-parse HEAD 2>/dev/null || true)}"
repo_name="${repo#*/}"

labels=(
  "org.opencontainers.image.title=${repo_name}/${name}"
  "org.opencontainers.image.description=${repo_name}/${name}"
  "org.opencontainers.image.vendor=Synkube"
  "org.opencontainers.image.licenses=${licenses}"
  "org.opencontainers.image.source=https://github.com/${repo}"
  "org.opencontainers.image.url=https://github.com/${repo}"
  "org.opencontainers.image.documentation=https://github.com/${repo}"
  "org.opencontainers.image.revision=${revision}"
)

if [[ -n "${version}" ]]; then
  labels+=("org.opencontainers.image.version=${version}")
fi

out=""
for l in "${labels[@]}"; do
  out+=" --label=${l}"
done
printf '%s\n' "${out# }"
