#!/usr/bin/env bash
# Generate a lab CA + per-service leaf certs. Idempotent — never overwrites
# an existing CA unless FORCE=1. Output layout matches what phase 4 wires
# into every JVM keystore/truststore and every OTLP HTTP endpoint.
#
# 04-SECURITY-GUARDRAILS §2 phase 4.
set -euo pipefail

: "${TLS_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certs}"
: "${FORCE:=0}"
: "${DAYS:=825}"
: "${KEYSIZE:=4096}"

mkdir -p "$TLS_DIR"

if [ -f "$TLS_DIR/ca.pem" ] && [ "$FORCE" != "1" ]; then
  echo "CA already exists at $TLS_DIR/ca.pem — set FORCE=1 to regenerate."
  exit 0
fi

echo "Generating lab CA under $TLS_DIR..."
openssl req -x509 -new -newkey "rsa:${KEYSIZE}" -nodes \
  -keyout "$TLS_DIR/ca.key" -out "$TLS_DIR/ca.pem" \
  -subj "/CN=kafka-project lab CA/O=lab" -days "$DAYS"

: "${STORE_PASSWORD:=changeit}"

leaf() {
  local svc="$1"; shift
  local sans="$1"; shift
  openssl req -new -newkey "rsa:${KEYSIZE}" -nodes \
    -keyout "$TLS_DIR/${svc}.key" -out "$TLS_DIR/${svc}.csr" \
    -subj "/CN=${svc}/O=lab"
  openssl x509 -req -in "$TLS_DIR/${svc}.csr" \
    -CA "$TLS_DIR/ca.pem" -CAkey "$TLS_DIR/ca.key" -CAcreateserial \
    -out "$TLS_DIR/${svc}.pem" -days "$DAYS" \
    -extfile <(printf "subjectAltName=%s" "$sans")
  rm -f "$TLS_DIR/${svc}.csr"

  # PKCS12 keystore (JVM services consume this directly — no BC needed).
  openssl pkcs12 -export \
    -in  "$TLS_DIR/${svc}.pem" \
    -inkey "$TLS_DIR/${svc}.key" \
    -certfile "$TLS_DIR/ca.pem" \
    -name "${svc}" \
    -passout "pass:${STORE_PASSWORD}" \
    -out "$TLS_DIR/${svc}.keystore.p12"

  # PKCS12 truststore holding only the lab CA — same file per service on
  # purpose, but kept per-svc so a future per-service trust chain does
  # not require refactoring every mount.
  keytool -importcert -noprompt -trustcacerts \
    -alias lab-ca -file "$TLS_DIR/ca.pem" \
    -keystore "$TLS_DIR/${svc}.truststore.p12" \
    -storetype PKCS12 -storepass "${STORE_PASSWORD}" 2>/dev/null || true
}

for svc in broker1 broker2 broker3 controller1 controller2 controller3 \
           schema-registry kafka-connect cruise-control kroxylicious \
           mcp-kafka otel-collector prometheus grafana akhq; do
  leaf "$svc" "DNS:${svc},DNS:localhost,IP:127.0.0.1"
done

echo "Done. Certs under $TLS_DIR — bind mount or COPY into service images."
ls -1 "$TLS_DIR"
