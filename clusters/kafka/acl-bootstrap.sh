#!/usr/bin/env bash
# Idempotent ACL bootstrap for the mTLS cluster (PR-9).
# Generates a temporary admin.properties at runtime and seeds
# least-privilege ACLs for every service principal.
# Safe to re-run: kafka-acls --add is idempotent.
set -euo pipefail

BS="${BOOTSTRAP:-broker1:9096}"
CC="/certs/admin.properties"

cat > "$CC" <<EOF
security.protocol=SSL
ssl.truststore.type=PKCS12
ssl.truststore.location=/certs/jks/admin/truststore.p12
ssl.truststore.password=changeit-dev-only
ssl.keystore.type=PKCS12
ssl.keystore.location=/certs/jks/admin/keystore.p12
ssl.keystore.password=changeit-dev-only
ssl.key.password=changeit-dev-only
ssl.endpoint.identification.algorithm=
EOF

ACL="kafka-acls --bootstrap-server $BS --command-config $CC"

# ---------- kafka-connect ----------
# Consume events, own internal topics, manage connector group
$ACL --add --allow-principal User:kafka-connect \
  --operation Read --operation Describe \
  --group connect-s3-sink

for t in events __connect-configs __connect-offsets __connect-status; do
  $ACL --add --allow-principal User:kafka-connect --operation All --topic "$t"
done

$ACL --add --allow-principal User:kafka-connect \
  --operation DescribeConfigs --cluster
$ACL --add --allow-principal User:kafka-connect \
  --operation Create --cluster

# ---------- loadgen ----------
$ACL --add --allow-principal User:loadgen \
  --operation Write --operation Describe --topic events

# ---------- schema-registry ----------
for op in Read Write Describe Create; do
  $ACL --add --allow-principal User:schema-registry \
    --operation "$op" --topic _schemas
done
$ACL --add --allow-principal User:schema-registry \
  --operation DescribeConfigs --cluster
$ACL --add --allow-principal User:schema-registry \
  --operation Create --cluster

# ---------- kminion ----------
$ACL --add --allow-principal User:kminion \
  --operation Describe --topic '*'
$ACL --add --allow-principal User:kminion \
  --operation Describe --group '*'
$ACL --add --allow-principal User:kminion \
  --operation Describe --cluster

# ---------- akhq ----------
$ACL --add --allow-principal User:akhq \
  --operation Describe --topic '*'
$ACL --add --allow-principal User:akhq \
  --operation Read    --topic '*'
$ACL --add --allow-principal User:akhq \
  --operation Describe --group '*'
$ACL --add --allow-principal User:akhq \
  --operation Describe --cluster

# ---------- mcp-kafka ----------
$ACL --add --allow-principal User:mcp-kafka --operation Describe --cluster
$ACL --add --allow-principal User:mcp-kafka --operation Read --topic '*'
$ACL --add --allow-principal User:mcp-kafka --operation Describe --topic '*'
$ACL --add --allow-principal User:mcp-kafka --operation Read --group 'mcp-tail-*'

# ---------- cruise-control ----------
for op in Describe DescribeConfigs Alter AlterConfigs; do
  $ACL --add --allow-principal User:cruise-control --operation "$op" --cluster
done
$ACL --add --allow-principal User:cruise-control --operation Describe --topic '*'
$ACL --add --allow-principal User:cruise-control --operation Read --topic '*'

echo "ACL bootstrap complete."
$ACL --list
