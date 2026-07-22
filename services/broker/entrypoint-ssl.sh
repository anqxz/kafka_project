#!/usr/bin/env bash
# Rewrites KAFKA_SSL_*_LOCATION into Confluent's expected
# KAFKA_SSL_*_FILENAME + _CREDENTIALS pair under /etc/kafka/secrets/,
# because cp-kafka's `configure` step gates SSL brokers on the FILENAME
# form (`dub ensure KAFKA_SSL_KEYSTORE_FILENAME`). Falls through to the
# stock entrypoint so nothing else about the boot path changes.
set -euo pipefail

SECRETS=/etc/kafka/secrets
mkdir -p "$SECRETS"

ks="${KAFKA_SSL_KEYSTORE_LOCATION:?KAFKA_SSL_KEYSTORE_LOCATION required}"
ts="${KAFKA_SSL_TRUSTSTORE_LOCATION:?KAFKA_SSL_TRUSTSTORE_LOCATION required}"

cp "$ks" "$SECRETS/keystore.p12"
cp "$ts" "$SECRETS/truststore.p12"

umask 077
printf '%s' "${KAFKA_SSL_KEYSTORE_PASSWORD:?}"   > "$SECRETS/keystore_creds"
printf '%s' "${KAFKA_SSL_TRUSTSTORE_PASSWORD:?}" > "$SECRETS/truststore_creds"
printf '%s' "${KAFKA_SSL_KEY_PASSWORD:?}"        > "$SECRETS/key_creds"

export KAFKA_SSL_KEYSTORE_FILENAME=keystore.p12
export KAFKA_SSL_KEYSTORE_CREDENTIALS=keystore_creds
export KAFKA_SSL_TRUSTSTORE_FILENAME=truststore.p12
export KAFKA_SSL_TRUSTSTORE_CREDENTIALS=truststore_creds
export KAFKA_SSL_KEY_CREDENTIALS=key_creds

unset KAFKA_SSL_KEYSTORE_LOCATION KAFKA_SSL_TRUSTSTORE_LOCATION \
      KAFKA_SSL_KEYSTORE_PASSWORD KAFKA_SSL_TRUSTSTORE_PASSWORD \
      KAFKA_SSL_KEY_PASSWORD

exec /etc/confluent/docker/run
