#!/usr/bin/env bash
set -euo pipefail

STEPPATH="${STEPPATH:-/step}"
export STEPPATH

OUT="${OUT:-/certs}"
CSV="${CSV:-/init/services.csv}"
PASS="changeit-dev-only"

# Publish CA material
mkdir -p "$OUT/ca"
cp "$STEPPATH/certs/root_ca.crt"         "$OUT/ca/root.crt"
cp "$STEPPATH/certs/intermediate_ca.crt" "$OUT/ca/intermediate.crt"
cat "$OUT/ca/intermediate.crt" "$OUT/ca/root.crt" > "$OUT/ca/ca-bundle.pem"

echo "==> Issuing per-service leaf certificates"
tail -n +2 "$CSV" | while IFS=, read -r svc cn sans; do
  [ -z "$svc" ] && continue
  pem_dir="$OUT/pem/$svc"
  jks_dir="$OUT/jks/$svc"
  mkdir -p "$pem_dir" "$jks_dir"

  # Build --san flags (comma-separated in CSV → multiple flags)
  san_flags=()
  IFS=';' read -ra san_list <<< "$sans"
  for s in "${san_list[@]}"; do
    [ -n "$s" ] && san_flags+=(--san "$s")
  done
  # Also add cn itself as SAN
  san_flags+=(--san "$cn")

  echo "  -> $svc ($cn)"
  step certificate create \
    --profile leaf \
    --not-after 2160h \
    --no-password \
    --insecure \
    --ca "$STEPPATH/certs/intermediate_ca.crt" \
    --ca-key "$STEPPATH/secrets/intermediate_ca_key" \
    "${san_flags[@]}" \
    "$cn" \
    "$pem_dir/tls.crt" \
    "$pem_dir/tls.key"

  cp "$OUT/ca/ca-bundle.pem" "$pem_dir/ca-bundle.pem"

  # PKCS12 keystore
  openssl pkcs12 -export \
    -in "$pem_dir/tls.crt" \
    -inkey "$pem_dir/tls.key" \
    -certfile "$OUT/ca/ca-bundle.pem" \
    -name "$svc" \
    -passout "pass:$PASS" \
    -out "$jks_dir/keystore.p12"

  # PKCS12 truststore (root + intermediate)
  openssl pkcs12 -export \
    -nokeys \
    -in "$OUT/ca/ca-bundle.pem" \
    -passout "pass:$PASS" \
    -out "$jks_dir/truststore.p12"
done

# Host admin client.properties
mkdir -p "$OUT/host"
cat > "$OUT/host/client.properties" <<EOF
security.protocol=SSL
ssl.truststore.location=/certs/jks/host-admin/truststore.p12
ssl.truststore.password=$PASS
ssl.truststore.type=PKCS12
ssl.keystore.location=/certs/jks/host-admin/keystore.p12
ssl.keystore.password=$PASS
ssl.keystore.type=PKCS12
EOF

# Per-broker client.properties (Task 3 addendum)
for n in 1 2 3; do
  cat > "$OUT/host/broker${n}-client.properties" <<EOF
security.protocol=SSL
ssl.truststore.location=/certs/jks/broker${n}/truststore.p12
ssl.truststore.password=$PASS
ssl.truststore.type=PKCS12
ssl.keystore.location=/certs/jks/broker${n}/keystore.p12
ssl.keystore.password=$PASS
ssl.keystore.type=PKCS12
EOF
done

echo "==> Certificate issuance complete."
