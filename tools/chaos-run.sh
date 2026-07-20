#!/usr/bin/env bash
# Chaos test harness — for each scenario in chaos-scenarios.yaml:
#   1. Apply the toxic via tools/chaos.sh
#   2. Poll Alertmanager /api/v2/alerts for the expected alert to reach `firing`
#   3. Assert detection time <= max_detect_seconds
#   4. Clear toxics, wait for the alert to resolve
# Exits non-zero on any assertion failure. Runs sequentially — chaos scenarios
# do not compose safely.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHAOS="$HERE/chaos.sh"
SCENARIOS_FILE="${SCENARIOS_FILE:-$HERE/chaos-scenarios.yaml}"
# Alertmanager is on the observability network only — not host-exposed. Default
# route: exec curl inside the prometheus container (same network). Override with
# ALERTMANAGER_API=http://host:port for a host-exposed setup.
ALERTMANAGER_API="${ALERTMANAGER_API:-}"
ALERTMANAGER_EXEC_CONTAINER="${ALERTMANAGER_EXEC_CONTAINER:-prometheus}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"
RESOLVE_TIMEOUT_SECONDS="${RESOLVE_TIMEOUT_SECONDS:-600}"
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
CONNECTOR_NAME="${CONNECTOR_NAME:-s3-sink-connector}"
CONNECTOR_CONFIG="${CONNECTOR_CONFIG:-$HERE/../connects/s3-sink-connector.json}"
CONNECTOR_READY_TIMEOUT_SECONDS="${CONNECTOR_READY_TIMEOUT_SECONDS:-60}"
SKIP_CONNECTOR_RELOAD="${SKIP_CONNECTOR_RELOAD:-0}"

for dep in yq jq curl; do
  command -v "$dep" >/dev/null || { echo "missing: $dep" >&2; exit 3; }
done

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

_alerts() {
  local q='/api/v2/alerts?active=true&silenced=false&inhibited=false'
  if [ -n "$ALERTMANAGER_API" ]; then
    curl -sS --fail "$ALERTMANAGER_API$q"
  else
    docker exec "$ALERTMANAGER_EXEC_CONTAINER" wget -qO- "http://alertmanager:9093$q"
  fi
}

_alert_firing() {
  local name=$1
  _alerts | jq -e --arg n "$name" '.[] | select(.labels.alertname == $n and .status.state == "active")' >/dev/null
}

_all_alerts() { _alerts | jq -r '.[] | "  \(.labels.alertname) → \(.status.state)"' | sort -u; }

# Ensure the connector exists and its live config matches CONNECTOR_CONFIG.
# Uses PUT /connectors/{name}/config (idempotent upsert). Polls until RUNNING.
ensure_connector() {
  [ "$SKIP_CONNECTOR_RELOAD" = "1" ] && { log "connector reload skipped (SKIP_CONNECTOR_RELOAD=1)"; return 0; }
  [ -f "$CONNECTOR_CONFIG" ] || { echo "connector config not found: $CONNECTOR_CONFIG" >&2; return 2; }

  local desired live
  desired=$(jq -c '.config' "$CONNECTOR_CONFIG")

  live=$(curl -sS "$CONNECT_URL/connectors/$CONNECTOR_NAME/config" 2>/dev/null || echo '{}')
  if [ "$(jq -cS . <<<"$live")" = "$(jq -cS . <<<"$desired")" ]; then
    log "connector $CONNECTOR_NAME already matches desired config"
  else
    log "applying $CONNECTOR_NAME config → $CONNECT_URL"
    curl -sS --fail -X PUT -H 'Content-Type: application/json' \
      --data "$desired" \
      "$CONNECT_URL/connectors/$CONNECTOR_NAME/config" >/dev/null
  fi

  local start elapsed state
  start=$(date +%s)
  while :; do
    state=$(curl -sS "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" 2>/dev/null \
      | jq -r '.connector.state // "UNKNOWN"')
    if [ "$state" = "RUNNING" ]; then
      log "connector $CONNECTOR_NAME state=RUNNING"
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$CONNECTOR_READY_TIMEOUT_SECONDS" ]; then
      log "✗ connector not RUNNING after ${elapsed}s (state=$state)"
      return 1
    fi
    sleep 2
  done
}

run_scenario() {
  local name="$1"
  local expect_alert max_detect
  expect_alert=$(yq -r ".scenarios[] | select(.name == \"$name\") | .expect_alert" "$SCENARIOS_FILE")
  max_detect=$(yq -r ".scenarios[] | select(.name == \"$name\") | .max_detect_seconds" "$SCENARIOS_FILE")

  log "▶ scenario=$name  expect=$expect_alert  budget=${max_detect}s"

  "$CHAOS" clear >/dev/null || true
  "$CHAOS" apply "$name" >/dev/null
  local start
  start=$(date +%s)

  # Poll until the expected alert fires or we run out of budget.
  while :; do
    if _alert_firing "$expect_alert"; then
      local elapsed=$(( $(date +%s) - start ))
      log "  ✓ $expect_alert firing after ${elapsed}s"
      "$CHAOS" clear >/dev/null || true
      [ "$elapsed" -le "$max_detect" ] || { log "  ✗ over budget (${elapsed}s > ${max_detect}s)"; return 1; }
      break
    fi
    local elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$max_detect" ]; then
      log "  ✗ $expect_alert did not fire within ${max_detect}s"
      log "  currently active alerts:"; _all_alerts || true
      "$CHAOS" clear >/dev/null || true
      return 1
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done

  # Best-effort: wait for the alert to resolve so the next scenario starts clean.
  log "  waiting for $expect_alert to resolve (up to ${RESOLVE_TIMEOUT_SECONDS}s)"
  local resolve_start
  resolve_start=$(date +%s)
  while _alert_firing "$expect_alert"; do
    if [ $(( $(date +%s) - resolve_start )) -ge "$RESOLVE_TIMEOUT_SECONDS" ]; then
      log "  ! alert still firing at deadline — leaving state and moving on"
      break
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

names=()
if [ $# -gt 0 ]; then
  names=("$@")
else
  mapfile -t names < <(yq -r '.scenarios[].name' "$SCENARIOS_FILE")
fi

ensure_connector || { echo "connector setup failed" >&2; exit 2; }

fail=0
for n in "${names[@]}"; do
  run_scenario "$n" || fail=1
done

exit "$fail"
