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

exec /etc/confluent/docker/run
