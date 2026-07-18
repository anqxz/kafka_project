#!/usr/bin/env bash
# Render /etc/kafka/kafka_server_jaas.conf from ${SCRAM_ADMIN_PASSWORD}
# and set KAFKA_OPTS so the JVM picks it up, then hand off to cp-kafka's
# stock entrypoint. Kafka refuses to start when a SASL listener is
# declared without a matching KafkaServer JAAS entry, even when
# inter-broker traffic stays PLAINTEXT.
#
# 04-SECURITY-GUARDRAILS §2 phase 2.
set -euo pipefail

: "${SCRAM_ADMIN_PASSWORD:?SCRAM_ADMIN_PASSWORD required}"

TEMPLATE=/etc/kafka/kafka_server_jaas.conf.template
TARGET=/etc/kafka/kafka_server_jaas.conf

sed "s|__SCRAM_ADMIN_PASSWORD__|${SCRAM_ADMIN_PASSWORD}|" \
  "$TEMPLATE" > "$TARGET"
chmod 0600 "$TARGET"

export KAFKA_OPTS="${KAFKA_OPTS:-} -Djava.security.auth.login.config=$TARGET"

exec /etc/confluent/docker/run "$@"
