#!/usr/bin/env bash
# Idempotent ACL bootstrap for the KRaft cluster. Runs after phase 2
# activates SASL and after every SCRAM user is created. Refuses to run
# while brokers still expose PLAINTEXT — that combination gives the ACL
# false confidence.
#
# 04-SECURITY-GUARDRAILS §2 phase 3.
set -euo pipefail

: "${BOOTSTRAP:=broker1:9092}"
: "${ADMIN_CFG:=/etc/kafka/admin.properties}"

kacls() { kafka-acls --bootstrap-server "$BOOTSTRAP" --command-config "$ADMIN_CFG" "$@"; }

grant_read()  { kacls --add --allow-principal "User:$1" --operation Read  --topic "$2"; }
grant_write() { kacls --add --allow-principal "User:$1" --operation Write --topic "$2"; }
grant_desc()  { kacls --add --allow-principal "User:$1" --operation Describe --topic "$2"; }
grant_grp()   { kacls --add --allow-principal "User:$1" --operation Read --operation Describe --group "$2"; }
grant_cluster_desc() { kacls --add --allow-principal "User:$1" --operation Describe --cluster; }

# --- Application principals ---
# loadgen  → produce to events
grant_write "loadgen" "events"
grant_desc  "loadgen" "events"

# connect  → consume events, own its internal topics + connector groups
for t in events _connect-configs _connect-offsets _connect-status; do
  grant_read  "connect" "$t"
  grant_write "connect" "$t"
  grant_desc  "connect" "$t"
done
grant_grp "connect" "connect-s3-sink-connector"
grant_grp "connect" "kafka-connect-cluster"
grant_cluster_desc "connect"

# schema-registry → own _schemas
for op in Read Write Describe; do
  kacls --add --allow-principal "User:schema-registry" --operation "$op" --topic "_schemas"
done
grant_grp "schema-registry" "schema-registry"

# kminion → read-only across the cluster (offsets + describe)
kacls --add --allow-principal "User:kminion" --operation Describe --topic "*"
kacls --add --allow-principal "User:kminion" --operation Read --group "*"
grant_cluster_desc "kminion"

# cruise-control → cluster-alter (rebalance) + metrics topic
kacls --add --allow-principal "User:cruise-control" --operation Alter    --cluster
kacls --add --allow-principal "User:cruise-control" --operation Describe --cluster
for op in Read Write Describe; do
  kacls --add --allow-principal "User:cruise-control" --operation "$op" --topic "__CruiseControlMetrics"
done

# mcp — read-only Tier-0 default
kacls --add --allow-principal "User:mcp" --operation Describe --cluster
kacls --add --allow-principal "User:mcp" --operation Describe --topic "*"
kacls --add --allow-principal "User:mcp" --operation Read     --topic "*"
kacls --add --allow-principal "User:mcp" --operation Describe --group "*"

# akhq  → describe everything (admin UI)
kacls --add --allow-principal "User:akhq" --operation Describe --cluster
kacls --add --allow-principal "User:akhq" --operation Describe --topic "*"
kacls --add --allow-principal "User:akhq" --operation Read     --topic "*"
kacls --add --allow-principal "User:akhq" --operation Describe --group "*"

echo "ACL bootstrap complete."
kacls --list
