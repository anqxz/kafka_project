#!/usr/bin/env bash
# Create every SCRAM-SHA-512 principal referenced by phase 2 REST auth and
# phase 3 ACLs. Idempotent — kafka-configs --alter overwrites the stored
# password when the entity already exists. Run against the PLAINTEXT
# listener while cut-over is still in progress, since the SASL listener
# will reject unknown users until this script seeds them.
#
# 04-SECURITY-GUARDRAILS §2 phase 2.
set -euo pipefail

: "${BOOTSTRAP:=broker1:9092}"

scram() {
  local user="$1"
  local pw="$2"
  kafka-configs --bootstrap-server "$BOOTSTRAP" \
    --alter --add-config "SCRAM-SHA-512=[iterations=8192,password=${pw}]" \
    --entity-type users --entity-name "$user"
}

scram "admin"           "${SCRAM_ADMIN_PASSWORD:?SCRAM_ADMIN_PASSWORD required}"
scram "connect"         "${SCRAM_CONNECT_PASSWORD:?}"
scram "schema-registry" "${SCRAM_SR_PASSWORD:?}"
scram "kminion"         "${SCRAM_KMINION_PASSWORD:?}"
scram "cruise-control"  "${SCRAM_CC_PASSWORD:?}"
scram "mcp"             "${SCRAM_MCP_PASSWORD:?}"
scram "loadgen"         "${SCRAM_LOADGEN_PASSWORD:?}"
scram "akhq"            "${SCRAM_AKHQ_PASSWORD:?}"

echo "SCRAM users seeded. Verify with:"
echo "  kafka-configs --bootstrap-server $BOOTSTRAP --describe --entity-type users"
