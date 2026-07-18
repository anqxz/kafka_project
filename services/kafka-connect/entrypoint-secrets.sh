#!/usr/bin/env bash
# Render Kafka Connect's SCRAM password to a tmpfs-backed file so the
# built-in FileConfigProvider can resolve `${file:…:password}` at
# property-read time. Enterprise deployments replace this whole file
# with a K8s Secret mount, Vault sidecar, or SPIRE issuance flow — the
# provider contract is the same either way.
#
# 04-SECURITY-GUARDRAILS §2 phase 5.
set -euo pipefail

: "${SECRETS_DIR:=/etc/kafka/connect-secrets}"

umask 0177
mkdir -p "$SECRETS_DIR"

if [ -n "${SCRAM_CONNECT_PASSWORD:-}" ]; then
  printf 'password=%s\n' "$SCRAM_CONNECT_PASSWORD" \
    > "${SECRETS_DIR}/connect.properties"
fi

exec /etc/confluent/docker/run "$@"
