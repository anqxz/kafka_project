#!/usr/bin/env bash
# One-shot orchestration for the ACL / SCRAM bootstrap. Waits for the
# PLAINTEXT listener to answer, then chains the three helpers we ship
# in the broker image. Idempotent end-to-end: kafka-configs --alter
# overwrites SCRAM entries, kafka-acls --add is a no-op on existing
# grants, and render-admin-props.sh always rewrites its target.
#
# 04-SECURITY-GUARDRAILS §2 phase 3.
set -euo pipefail

: "${BOOTSTRAP:=broker1:9092}"
: "${WAIT_TIMEOUT:=120}"

# Kafka CLIs inherit KAFKA_OPTS from the broker image, which includes
# `-javaagent:...jmx_prometheus_javaagent.jar=7071:...`. Running the CLI
# in-cluster tries to bind the same port and fails. Neutralise it here
# — the CLI does not need JMX metrics.
unset KAFKA_OPTS

echo "waiting up to ${WAIT_TIMEOUT}s for ${BOOTSTRAP}..."
deadline=$(( SECONDS + WAIT_TIMEOUT ))
until kafka-broker-api-versions --bootstrap-server "${BOOTSTRAP}" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "timed out waiting for ${BOOTSTRAP}" >&2
    exit 1
  fi
  sleep 2
done
echo "broker reachable — running bootstrap chain."

/usr/local/bin/render-admin-props.sh
/usr/local/bin/bootstrap-scram-users.sh
# ACLs require an authenticated admin client — talk to the SASL
# listener on :9095, not the PLAINTEXT one used for the readiness probe.
BOOTSTRAP="${BOOTSTRAP%%:*}:9095" ADMIN_CFG=/etc/kafka/admin.properties \
  /usr/local/bin/bootstrap-acls.sh

echo "kafka-init done."
