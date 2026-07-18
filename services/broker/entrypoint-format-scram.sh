#!/usr/bin/env bash
# Pre-format the broker's metadata log with the admin SCRAM credential
# baked in, then hand off to the upstream cp-kafka entrypoint. Baking
# the admin at format time is the only way to solve the chicken-and-egg
# problem where the first broker startup needs to authenticate to its
# peers over SASL before any client can call kafka-configs to create
# users.
#
# Idempotent: skips the format when metadata.properties already exists,
# so restarts are safe. First-time formatting requires
# `docker compose down -v` on an already-running cluster.
#
# 04-SECURITY-GUARDRAILS §2 phase 2 (inter-broker cut-over prep).
set -euo pipefail

: "${KAFKA_CLUSTER_ID:?KAFKA_CLUSTER_ID required}"
: "${KAFKA_LOG_DIRS:=/var/lib/kafka/data}"
: "${SCRAM_ADMIN_USER:=admin}"

if [ -f "${KAFKA_LOG_DIRS}/meta.properties" ] || \
   [ -f "${KAFKA_LOG_DIRS}/__cluster_metadata-0/meta.properties" ]; then
  echo "meta.properties present — skipping format (existing cluster)."
else
  if [ -z "${SCRAM_ADMIN_PASSWORD:-}" ]; then
    echo "SCRAM_ADMIN_PASSWORD unset — falling back to plain format." >&2
    kafka-storage format --ignore-formatted \
      --cluster-id "${KAFKA_CLUSTER_ID}" \
      --config /etc/kafka/kafka.properties
  else
    echo "Formatting ${KAFKA_LOG_DIRS} with admin SCRAM baked in."
    kafka-storage format --ignore-formatted \
      --cluster-id "${KAFKA_CLUSTER_ID}" \
      --config /etc/kafka/kafka.properties \
      --add-scram "SCRAM-SHA-512=[name=${SCRAM_ADMIN_USER},password=${SCRAM_ADMIN_PASSWORD}]"
  fi
fi

exec /etc/confluent/docker/run "$@"
