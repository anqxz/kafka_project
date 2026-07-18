#!/usr/bin/env bash
# Seed LocalStack Secrets Manager with lab secrets. Phase 5 config providers
# in Connect / Schema Registry / MCP resolve every credential through these
# ARNs, so rotating one secret is a single API call instead of a redeploy.
#
# 04-SECURITY-GUARDRAILS §2 phase 5.
set -euo pipefail

put() {
  local name="$1"; shift
  local value="$1"; shift
  awslocal secretsmanager describe-secret --secret-id "$name" >/dev/null 2>&1 && {
    awslocal secretsmanager update-secret --secret-id "$name" --secret-string "$value"
    return
  }
  awslocal secretsmanager create-secret --name "$name" --secret-string "$value"
}

put "kafka/grafana/admin"          "${GRAFANA_ADMIN_PASSWORD:-change-me-in-real-deployments}"
put "kafka/ntfy/alerts-topic"      "${NTFY_ALERT_TOPIC:-kafka-alerts-c3f8a2d1}"
put "kafka/ntfy/watchdog-topic"    "${NTFY_WATCHDOG_TOPIC:-kafka-watchdog-c3f8a2d1}"
put "kafka/mcp/token"              "${MCP_AUTH_TOKEN:-change-me-in-real-deployments}"
put "kafka/schema-registry/admin"  "${SCHEMA_REGISTRY_ADMIN_PASSWORD:-change-me-in-real-deployments}"
put "kafka/cruise-control/admin"   "${CRUISE_CONTROL_ADMIN_PASSWORD:-change-me-in-real-deployments}"
put "kafka/scram/admin"            "${SCRAM_ADMIN_PASSWORD:-change-me-in-real-deployments}"
put "kafka/scram/connect"          "${SCRAM_CONNECT_PASSWORD:-change-me-in-real-deployments}"
put "kafka/scram/kminion"          "${SCRAM_KMINION_PASSWORD:-change-me-in-real-deployments}"
put "kafka/scram/cruise-control"   "${SCRAM_CC_PASSWORD:-change-me-in-real-deployments}"
put "kafka/scram/mcp"              "${SCRAM_MCP_PASSWORD:-change-me-in-real-deployments}"
put "kafka/scram/loadgen"          "${SCRAM_LOADGEN_PASSWORD:-change-me-in-real-deployments}"
put "kafka/scram/schema-registry"  "${SCRAM_SR_PASSWORD:-change-me-in-real-deployments}"
put "kafka/scram/akhq"             "${SCRAM_AKHQ_PASSWORD:-change-me-in-real-deployments}"

echo "Secrets Manager seeded:"
awslocal secretsmanager list-secrets --query 'SecretList[].Name' --output text
