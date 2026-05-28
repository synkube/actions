#!/usr/bin/env bash
# Update YAML scalar values on lines marked with # github-workflow-managed:<key>.
#
# Supported line shapes on the same line as the marker:
#   tag: "1.2.3" # github-workflow-managed:service.tag
#   image: ghcr.io/org/repo/name:1.2.3 # github-workflow-managed:opa.image
set -euo pipefail

fail() {
  echo "::error::$1"
  exit 1
}

FILE="${1:-}"
MANAGED_KEY="${2:-}"
VERSION="${3:-}"

[[ -n "${FILE}" && -f "${FILE}" ]] || fail "file not found: ${FILE:-<empty>}"
[[ -n "${MANAGED_KEY}" ]] || fail "managed_key is required"
[[ -n "${VERSION}" ]] || fail "version is required"

MARKER="# github-workflow-managed:${MANAGED_KEY}"

python3 - "${FILE}" "${MARKER}" "${VERSION}" <<'PY'
import re
import sys

path, marker, version = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
updated = False

tag_re = re.compile(r'^(\s*tag:\s*["\'])([^"\']*)(["\'])(\s*' + re.escape(marker) + r'\s*)$')
image_re = re.compile(r'^(\s*image:\s*\S+:)([^ \t#]+)(\s*' + re.escape(marker) + r'\s*)$')

out = []
for line in lines:
    if marker not in line:
        out.append(line)
        continue

    newline = line
    m = tag_re.match(line.rstrip("\n"))
    if m:
        newline = f'{m.group(1)}{version}{m.group(3)}{m.group(4)}\n'
        updated = True
    else:
        m = image_re.match(line.rstrip("\n"))
        if m:
            newline = f'{m.group(1)}{version}{m.group(3)}\n'
            updated = True
        else:
            msg = (
                f"unsupported managed line for {marker!r} in {path}: "
                f"expected tag: \"…\" or image: repo:tag before the marker"
            )
            print(f"::error::{msg}", file=sys.stderr)
            sys.exit(1)

    out.append(newline)

if not updated:
    print(f"::error::no line updated for marker {marker!r} in {path}", file=sys.stderr)
    sys.exit(1)

with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(out)

print(f"Updated {path} ({marker}) -> {version}")
PY
