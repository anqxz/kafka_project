#!/usr/bin/env bash
# Re-export all .drawio files in this directory to .svg
# Usage: ./export.sh [file.drawio]   (no arg = export all)
set -euo pipefail
cd "$(dirname "$0")"

export_one() {
  local f="$1"
  local out="${f%.drawio}.svg"
  xvfb-run -a drawio -x -f svg -o "$out" "$f" >/dev/null 2>&1 \
    && echo "OK  $out" \
    || echo "FAIL $f"
}

if [ $# -gt 0 ]; then
  export_one "$1"
else
  for f in *.drawio; do
    export_one "$f"
  done
fi
