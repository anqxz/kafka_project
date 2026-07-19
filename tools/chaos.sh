#!/usr/bin/env bash
# Toxiproxy chaos control — apply / clear / status toxics against the
# connect-to-localstack proxy. Auto-expiring where the toxic type supports it.
# Uses the Toxiproxy REST API on 127.0.0.1:8474.
set -euo pipefail

TOXIPROXY_API=${TOXIPROXY_API:-http://127.0.0.1:8474}
PROXY=${PROXY:-connect-to-localstack}
SCENARIOS_FILE=${SCENARIOS_FILE:-$(dirname "$0")/chaos-scenarios.yaml}

die() { echo "chaos: $*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

require curl
require jq

# yq is optional — only needed for `apply <scenario_name>`. Direct toxic
# payloads via `apply-raw` don't require it.
have_yq() { command -v yq >/dev/null 2>&1; }

api() { curl -sS --fail "$@"; }

_proxy_exists() {
  api "$TOXIPROXY_API/proxies/$PROXY" >/dev/null 2>&1
}

cmd_status() {
  _proxy_exists || die "proxy $PROXY not found on $TOXIPROXY_API"
  echo "proxy:"
  api "$TOXIPROXY_API/proxies/$PROXY" | jq '{name, listen, upstream, enabled}'
  echo "toxics:"
  api "$TOXIPROXY_API/proxies/$PROXY/toxics" | jq '.'
}

cmd_clear() {
  _proxy_exists || die "proxy $PROXY not found"
  # Remove every toxic on the proxy.
  api "$TOXIPROXY_API/proxies/$PROXY/toxics" | jq -r '.[].name' | while read -r t; do
    [ -n "$t" ] || continue
    echo "removing toxic: $t"
    api -X DELETE "$TOXIPROXY_API/proxies/$PROXY/toxics/$t" || true
  done
}

# apply-raw <name> <type> <stream> <attributes_json>
cmd_apply_raw() {
  local name=$1 type=$2 stream=$3 attrs=$4
  _proxy_exists || die "proxy $PROXY not found"
  local body
  body=$(jq -n \
    --arg name "$name" \
    --arg type "$type" \
    --arg stream "$stream" \
    --argjson attrs "$attrs" \
    '{name:$name, type:$type, stream:$stream, toxicity:1.0, attributes:$attrs}')
  echo "$body" | api -X POST -H 'Content-Type: application/json' \
    -d @- "$TOXIPROXY_API/proxies/$PROXY/toxics" | jq '.'
}

cmd_apply() {
  local scenario=$1
  have_yq || die "yq is required for named scenarios (fall back: apply-raw)"
  [ -f "$SCENARIOS_FILE" ] || die "scenarios file not found: $SCENARIOS_FILE"
  local type stream attrs
  type=$(yq -r ".scenarios[] | select(.name == \"$scenario\") | .toxic.type" "$SCENARIOS_FILE")
  stream=$(yq -r ".scenarios[] | select(.name == \"$scenario\") | .toxic.stream" "$SCENARIOS_FILE")
  attrs=$(yq -o=json ".scenarios[] | select(.name == \"$scenario\") | .toxic.attributes" "$SCENARIOS_FILE")
  [ -n "$type" ] && [ "$type" != "null" ] || die "scenario not found: $scenario"
  cmd_apply_raw "$scenario" "$type" "$stream" "$attrs"
}

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <command> [args]

commands:
  status                              print proxy + active toxics
  clear                               remove all toxics on $PROXY
  apply <scenario_name>               apply a named scenario from
                                      $SCENARIOS_FILE (requires yq)
  apply-raw <name> <type> <stream> <attrs_json>
                                      apply an ad-hoc toxic
                                      e.g. apply-raw slow latency upstream '{"latency":800}'

env:
  TOXIPROXY_API   default $TOXIPROXY_API
  PROXY           default $PROXY
  SCENARIOS_FILE  default $SCENARIOS_FILE
EOF
  exit 2
}

case "${1:-}" in
  status)     cmd_status ;;
  clear)      cmd_clear ;;
  apply)      shift; cmd_apply "${1:?scenario name required}" ;;
  apply-raw)  shift; cmd_apply_raw "${1:?name}" "${2:?type}" "${3:?stream}" "${4:?attrs_json}" ;;
  *)          usage ;;
esac
