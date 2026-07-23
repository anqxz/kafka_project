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

# Render JMX Exporter config that serves :7071 over HTTPS with the
# SR leaf. Same pattern as broker/controller entrypoints.
HOST="${KAFKA_JMX_HOSTNAME:-$(hostname)}"
JMX_TLS_CONFIG=/tmp/kafka-jmx-tls.yml
cp /opt/jmx_exporter/kafka-config.yml "$JMX_TLS_CONFIG"
cat >> "$JMX_TLS_CONFIG" <<EOF

httpServer:
  ssl:
    keyStore:
      filename: /certs/jks/${HOST}/keystore.p12
      password: changeit-dev-only
      type: PKCS12
    certificate:
      alias: ${HOST}
EOF
export SCHEMA_REGISTRY_OPTS="${SCHEMA_REGISTRY_OPTS//\/opt\/jmx_exporter\/kafka-config.yml/${JMX_TLS_CONFIG}}"

exec /etc/confluent/docker/run
