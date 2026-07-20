#!/usr/bin/env bash
set -euo pipefail

STEPPATH="${STEPPATH:-/step}"
export STEPPATH

mkdir -p "$STEPPATH/certs" "$STEPPATH/secrets"

if [ -f "$STEPPATH/certs/root_ca.crt" ]; then
  echo "PKI already initialised — skipping."
  exit 0
fi

echo "==> Initialising Root CA (10y)"
step certificate create \
  --profile root-ca \
  --not-after 87600h \
  --no-password \
  --insecure \
  "Kafka Lab Root CA" \
  "$STEPPATH/certs/root_ca.crt" \
  "$STEPPATH/secrets/root_ca_key"

echo "==> Initialising Intermediate CA (5y)"
step certificate create \
  --profile intermediate-ca \
  --not-after 43800h \
  --no-password \
  --insecure \
  --ca "$STEPPATH/certs/root_ca.crt" \
  --ca-key "$STEPPATH/secrets/root_ca_key" \
  "Kafka Lab Intermediate CA" \
  "$STEPPATH/certs/intermediate_ca.crt" \
  "$STEPPATH/secrets/intermediate_ca_key"

echo "==> PKI bootstrap complete."
