#!/usr/bin/env bash
# Render /etc/schema-registry/password.properties from env, then hand off
# to the upstream entrypoint. Basic-auth realm = SchemaRegistry.
set -euo pipefail

if [ -n "${SCHEMA_REGISTRY_ADMIN_USER:-}" ] && [ -n "${SCHEMA_REGISTRY_ADMIN_PASSWORD:-}" ]; then
  {
    echo "${SCHEMA_REGISTRY_ADMIN_USER}: ${SCHEMA_REGISTRY_ADMIN_PASSWORD},admin"
  } > /etc/schema-registry/password.properties
  chmod 0600 /etc/schema-registry/password.properties
fi

# Phase 5: render the kafkastore SCRAM password to a file so SR's
# built-in FileConfigProvider can resolve ${file:…:password} at
# property-read time. Enterprise deployments swap this render step for
# a K8s Secret projected volume, a Vault sidecar, or SPIRE issuance —
# the provider contract stays identical.
if [ -n "${SCRAM_SR_PASSWORD:-}" ]; then
  umask 0177
  mkdir -p /etc/schema-registry/secrets
  printf 'password=%s\n' "$SCRAM_SR_PASSWORD" \
    > /etc/schema-registry/secrets/kafkastore.properties
fi

exec /etc/confluent/docker/run
