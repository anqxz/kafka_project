#!/usr/bin/env bash
# Render a JMX Exporter config that serves :7071 over HTTPS with the
# controller's own leaf, then hand off to the stock cp-kafka entrypoint.
# Same shape as brokers/entrypoint-ssl.sh — but controllers have no
# other SSL rewriting to do, so this file only exists for the JMX flip.
set -euo pipefail

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

exec /etc/confluent/docker/run
