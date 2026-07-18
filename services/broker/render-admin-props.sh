#!/usr/bin/env bash
# Render /etc/kafka/admin.properties from SCRAM_ADMIN_PASSWORD so that
# in-container CLIs (kafka-acls, kafka-configs) can talk to the SASL
# listener without a static credential baked into the image. Called on
# demand — the broker entrypoint itself does not need it, only the
# bootstrap-* helper scripts.
#
# 04-SECURITY-GUARDRAILS §2 phase 2.
set -euo pipefail

: "${SCRAM_ADMIN_USER:=admin}"
: "${SCRAM_ADMIN_PASSWORD:?SCRAM_ADMIN_PASSWORD required}"
: "${ADMIN_CFG:=/etc/kafka/admin.properties}"

umask 0177
mkdir -p "$(dirname "$ADMIN_CFG")"
cat > "$ADMIN_CFG" <<PROPS
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required \
  username="${SCRAM_ADMIN_USER}" \
  password="${SCRAM_ADMIN_PASSWORD}";
PROPS

echo "Wrote $ADMIN_CFG"
