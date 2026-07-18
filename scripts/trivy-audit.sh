#!/usr/bin/env bash
# Local reproduction of the security.yml Trivy job.
#
# Usage:
#   scripts/trivy-audit.sh <service>          # build + scan one service
#   scripts/trivy-audit.sh --all              # every service under services/
#   scripts/trivy-audit.sh <service> --write  # scan + overwrite .trivyignore
#                                             #   with every finding
#   scripts/trivy-audit.sh <service> --diff   # scan + show CVEs NOT already
#                                             #   listed in .trivyignore
#
# Env knobs:
#   TRIVY_SEVERITY   default CRITICAL,HIGH
#   TRIVY_CACHE_DIR  default $HOME/.cache/trivy
#   TRIVY_TAG        default aquasec/trivy:latest (fallback if trivy CLI absent)
#   EXPIRY           default 2026-10-31 — filled into --write output
#   TICKET           default SEC-TBD    — filled into --write output
#
# 04-SECURITY-GUARDRAILS §2 phase 6.
set -euo pipefail

: "${TRIVY_SEVERITY:=CRITICAL,HIGH}"
: "${TRIVY_CACHE_DIR:=$HOME/.cache/trivy}"
: "${TRIVY_TAG:=aquasec/trivy:latest}"
: "${EXPIRY:=2026-10-31}"
: "${TICKET:=SEC-TBD}"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$TRIVY_CACHE_DIR"

trivy() {
  if command -v trivy >/dev/null 2>&1; then
    command trivy "$@"
  else
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$TRIVY_CACHE_DIR":/root/.cache/trivy \
      -v "$repo_root":/work -w /work \
      "$TRIVY_TAG" "$@"
  fi
}

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" >&2
  exit 1
}

audit_one() {
  local svc="$1"
  local mode="${2:-report}"
  local ctx="$repo_root/services/$svc"
  local ignore="$ctx/.trivyignore"
  local img="kproj-${svc}:ci"

  [ -d "$ctx" ] || { echo "no such service: $svc" >&2; return 1; }

  echo "─── $svc ─────────────────────────────────────"
  echo "build: $img"
  ( cd "$repo_root" && docker build -q -t "$img" "services/$svc" >/dev/null )

  local report_json
  report_json=$(mktemp)
  trivy image --quiet \
    --cache-dir /root/.cache/trivy \
    --ignore-unfixed \
    --severity "$TRIVY_SEVERITY" \
    --format json \
    "$img" > "$report_json" 2>/dev/null || true

  # CVE IDs, deduped, sorted.
  local cves
  cves=$(jq -r '.Results[]?.Vulnerabilities[]?.VulnerabilityID' "$report_json" | sort -u)
  local n=$(printf '%s\n' "$cves" | grep -c '^CVE-' || true)

  case "$mode" in
    report)
      echo "findings: $n CRITICAL/HIGH"
      if [ "$n" -gt 0 ]; then
        trivy image --quiet \
          --cache-dir /root/.cache/trivy \
          --ignore-unfixed --severity "$TRIVY_SEVERITY" \
          --format table "$img"
      fi
      ;;

    write)
      echo "findings: $n — writing $ignore"
      {
        cat <<EOF
# Risk-accepted CVEs — populated by scripts/trivy-audit.sh --write.
#
# Format:
#   CVE-YYYY-NNNNN  # expiry:YYYY-MM-DD  ticket:SEC-XXXX  reason:<short>
#
# Every line here suppresses the CVE at scan time. When Renovate opens
# the vendor-tag bump PR that closes the underlying finding, drop the
# corresponding line here.

EOF
        printf '%s\n' "$cves" | grep '^CVE-' | while read -r c; do
          printf '%s  # expiry:%s  ticket:%s  reason:vendor-image-baseline\n' \
            "$c" "$EXPIRY" "$TICKET"
        done
      } > "$ignore"
      ;;

    diff)
      # Anything the scan produced that isn't already in .trivyignore.
      local already
      already=$( { grep -oE '^CVE-[0-9]{4}-[0-9]+' "$ignore" 2>/dev/null || true; } | sort -u )
      local missing
      missing=$(comm -23 <(printf '%s\n' "$cves" | grep '^CVE-' | sort -u) <(printf '%s\n' "$already"))
      local m=$(printf '%s\n' "$missing" | grep -c '^CVE-' || true)
      echo "unlisted findings: $m"
      [ "$m" -gt 0 ] && printf '%s\n' "$missing"
      ;;
  esac

  rm -f "$report_json"
}

case "${1:-}" in
  ""|-h|--help) usage ;;
  --all)
    for d in "$repo_root"/services/*/; do
      audit_one "$(basename "$d")" report
    done
    ;;
  *)
    svc="$1"; shift || true
    case "${1:-}" in
      --write) audit_one "$svc" write ;;
      --diff)  audit_one "$svc" diff ;;
      "")      audit_one "$svc" report ;;
      *)       echo "unknown flag: $1" >&2; usage ;;
    esac
    ;;
esac
