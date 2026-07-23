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

# REST basic-auth (04-SECURITY-GUARDRAILS §2 phase 2 — Connect REST hardening).
# BasicAuthSecurityRestExtension reads a JAAS entry named `KafkaConnect`
# whose PropertyFileLoginModule points at a colon-delimited user file.
if [ -n "${CONNECT_REST_BASIC_USER:-}" ] && [ -n "${CONNECT_REST_BASIC_PASSWORD:-}" ]; then
  printf '%s: %s,admin\n' \
    "$CONNECT_REST_BASIC_USER" "$CONNECT_REST_BASIC_PASSWORD" \
    > "${SECRETS_DIR}/rest-auth.properties"
  cat > "${SECRETS_DIR}/rest-auth.jaas" <<JAAS
KafkaConnect {
  org.apache.kafka.connect.rest.basic.auth.extension.PropertyFileLoginModule required
  file="${SECRETS_DIR}/rest-auth.properties";
};
JAAS
fi

# Render JMX Exporter config that serves :7071 over HTTPS with the
# kafka-connect leaf. Same pattern as broker/controller entrypoints.
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
export KAFKA_OPTS="${KAFKA_OPTS//\/opt\/jmx_exporter\/kafka-config.yml/${JMX_TLS_CONFIG}}"

exec /etc/confluent/docker/run "$@"
