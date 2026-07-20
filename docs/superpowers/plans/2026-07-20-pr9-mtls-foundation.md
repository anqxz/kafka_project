# PR 9 — mTLS Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every Kafka network path (client↔broker, inter-broker, controller quorum, host↔broker external) with mTLS. Enable StandardAuthorizer + least-privilege ACLs. Provision PKI via step-ca with a Root+Intermediate CA. Remove PR 8 basic-auth (Connect REST becomes client-cert authenticated). Emit both PEM and PKCS12 per leaf.

**Architecture:** step-ca one-shot bootstraps Root(10y)+Intermediate(5y) into named volume `pki-root`. `bootstrap-certs` iterates a service→CN table and mints 90d leaves into `pki-certs` (PEM + PKCS12). Brokers/controllers listen SSL-only. `acl-bootstrap` seeds ACLs after brokers healthy. Every client service is switched to SSL with mounted trust material. `tools/kafka.sh` becomes an SSL wrapper for host tooling. Cert-expiry monitored via blackbox exporter.

**Tech Stack:** step-ca (`smallstep/step-ca`) + step-cli, Apache Kafka 3.8.x (KRaft, existing), Docker Compose, Prometheus + blackbox-exporter, Loki (for auth-failure log queries), bash, openssl, kcat/kafka CLIs.

## Global Constraints

- No plaintext, no SASL, no SASL_SSL listeners survive PR 9. `docker compose up` after PR 9 = mTLS everywhere.
- Cert CN → principal via `ssl.principal.mapping.rules=RULE:^CN=(.*?),.*$/$1/L,DEFAULT`. Set on brokers AND controllers.
- Authorizer: `org.apache.kafka.metadata.authorizer.StandardAuthorizer`. `allow.everyone.if.no.acl.found=false`.
- Super users (enumerate — no wildcard): `User:admin;User:host-admin;User:broker1;User:broker2;User:broker3;User:controller1;User:controller2;User:controller3`.
- All keystore/truststore passwords in dev: `changeit-dev-only`. Document; do not vary.
- All leaf certs 90d, Intermediate 5y, Root 10y.
- PR 8 basic-auth on Connect REST is REMOVED; Connect REST becomes HTTPS with `ssl.client.auth=required`.
- Every task ends `git commit` on branch `pr9-mtls-foundation`.
- Task N MUST leave the stack in a running-and-testable state (unless a task's Step explicitly ends with `down -v` for the next task's fresh boot).

---

## File Structure

- Create `clusters/step-ca/Dockerfile` — cert-issuer image (step-cli + openssl).
- Create `clusters/step-ca/init/step-ca-init.sh` — Root + Intermediate bootstrap.
- Create `clusters/step-ca/init/bootstrap-certs.sh` — mint leaves per `services.csv`.
- Create `clusters/step-ca/init/services.csv` — `<svc>,<cn>,<sans>` table.
- Create `clusters/kafka/acl-bootstrap.sh` — idempotent ACL seed.
- Create `blackbox/blackbox.yml` — add `ssl_cert_expiry` module (or modify if exists).
- Create `prometheus/rules/mtls.rules.yml` — expiry rule + 3 alerts.
- Create `grafana/dashboards/kafka-security.json` — auth-failure + cert-expiry panels.
- Create `tools/mtls-verify.sh` — integration proof.
- Create `tools/cert-rotate.sh` — manual leaf rotation helper.
- Modify `clusters/docker-compose.yml` — extensive: listeners, envs, new services, volumes.
- Modify `services/kafka-connect/entrypoint-secrets.sh` — emit ssl.properties, strip basic-auth.
- Modify `services/loadgen/app/loadgen.py` — SSL producer args.
- Modify `services/mcp-kafka/app/server.py` — SSL client args.
- Modify `services/kminion/kminion.yaml` — TLS block replacing SASL.
- Modify `services/akhq/application.yml` — cluster SSL block.
- Modify `services/cruise-control/config/cruisecontrol.properties` — SSL props.
- Modify `services/schema-registry/*` — env-driven SSL.
- Modify `prometheus/prometheus.yml` — cert_expiry job.
- Modify `tools/kafka.sh` — SSL wrapper.
- Modify `tools/chaos-run.sh` — 2 new scenarios.
- Modify `04-SECURITY-GUARDRAILS.md`, `02-INTEGRATION-ARCHITECTURE.md`, `03-DATA-FLOW-ARCHITECTURE.md`.
- Delete `services/kafka-connect/rest-auth.jaas` and PR 8 basic-auth entrypoint bits.

---

## Task 1: PKI foundation — step-ca-init + cert-issuer image + bootstrap-certs

**Files:**
- Create: `clusters/step-ca/Dockerfile`
- Create: `clusters/step-ca/init/step-ca-init.sh`
- Create: `clusters/step-ca/init/bootstrap-certs.sh`
- Create: `clusters/step-ca/init/services.csv`
- Modify: `clusters/docker-compose.yml` (add services + volumes; nothing else yet)

**Interfaces:**
- Produces: named volume `pki-root` (Root+Intermediate keys, step config); named volume `pki-certs` (per-service `pem/` and `jks/` dirs, plus `ca/ca-bundle.pem`). Password `changeit-dev-only`. Alias `alias/kroxylicious-events` NOT touched (that's PR 10).

- [ ] **Step 1: services.csv**

Create `clusters/step-ca/init/services.csv`:

```csv
svc,cn,sans
broker1,broker1,broker1
broker2,broker2,broker2
broker3,broker3,broker3
controller1,controller1,controller1
controller2,controller2,controller2
controller3,controller3,controller3
kafka-connect,kafka-connect,kafka-connect
schema-registry,schema-registry,schema-registry
akhq,akhq,akhq
kminion,kminion,kminion
cruise-control,cruise-control,cruise-control
loadgen,loadgen,loadgen
mcp-kafka,mcp-kafka,mcp-kafka
admin,admin,admin
host-admin,host-admin,localhost
```

- [ ] **Step 2: step-ca-init.sh (Root + Intermediate)**

Create `clusters/step-ca/init/step-ca-init.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

STEPPATH="${STEPPATH:-/step}"
export STEPPATH

if [ -f "$STEPPATH/certs/root_ca.crt" ] && [ -f "$STEPPATH/certs/intermediate_ca.crt" ]; then
  echo "PKI already initialized at $STEPPATH — nothing to do."
  exit 0
fi

mkdir -p "$STEPPATH/secrets"
echo "changeit-dev-only" > "$STEPPATH/secrets/password"

step ca init \
  --name "kafka-lab" \
  --dns "step-ca" \
  --address ":9000" \
  --provisioner "admin" \
  --password-file "$STEPPATH/secrets/password" \
  --provisioner-password-file "$STEPPATH/secrets/password" \
  --deployment-type standalone

echo "root+intermediate created:"
ls "$STEPPATH/certs"
```

- [ ] **Step 3: bootstrap-certs.sh**

Create `clusters/step-ca/init/bootstrap-certs.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

STEPPATH="${STEPPATH:-/step}"
OUT="${OUT:-/certs}"
CSV="${CSV:-/init/services.csv}"
PW="changeit-dev-only"

mkdir -p "$OUT/ca"
cp "$STEPPATH/certs/root_ca.crt" "$OUT/ca/root.crt"
cp "$STEPPATH/certs/intermediate_ca.crt" "$OUT/ca/intermediate.crt"
cat "$OUT/ca/root.crt" "$OUT/ca/intermediate.crt" > "$OUT/ca/ca-bundle.pem"

tail -n +2 "$CSV" | while IFS=, read -r svc cn sans; do
  [ -z "$svc" ] && continue
  pem_dir="$OUT/pem/$svc"
  jks_dir="$OUT/jks/$svc"
  mkdir -p "$pem_dir" "$jks_dir"

  if [ ! -f "$pem_dir/tls.crt" ]; then
    echo "issuing leaf: cn=$cn sans=$sans"
    # OFFLINE signing via intermediate — no long-lived CA server (dev-only)
    step certificate create "$cn" "$pem_dir/tls.crt" "$pem_dir/tls.key" \
      --profile leaf \
      --ca "$STEPPATH/certs/intermediate_ca.crt" \
      --ca-key "$STEPPATH/secrets/intermediate_ca_key" \
      --ca-password-file "$STEPPATH/secrets/password" \
      --san "$sans" \
      --not-after 2160h \
      --no-password --insecure --force
    ln -sf ../../ca/ca-bundle.pem "$pem_dir/ca-bundle.pem"

    openssl pkcs12 -export \
      -in "$pem_dir/tls.crt" \
      -inkey "$pem_dir/tls.key" \
      -certfile "$OUT/ca/ca-bundle.pem" \
      -name "$cn" \
      -out "$jks_dir/keystore.p12" \
      -passout "pass:$PW"

    keytool -import -noprompt -trustcacerts \
      -alias root -file "$OUT/ca/root.crt" \
      -keystore "$jks_dir/truststore.p12" -storetype PKCS12 -storepass "$PW"
    keytool -import -noprompt -trustcacerts \
      -alias intermediate -file "$OUT/ca/intermediate.crt" \
      -keystore "$jks_dir/truststore.p12" -storetype PKCS12 -storepass "$PW"

    openssl verify -CAfile "$OUT/ca/ca-bundle.pem" "$pem_dir/tls.crt"
  fi
done

# host client.properties
cat > "$OUT/host/client.properties" <<EOF
security.protocol=SSL
ssl.truststore.type=PKCS12
ssl.truststore.location=/certs/jks/host-admin/truststore.p12
ssl.truststore.password=$PW
ssl.keystore.type=PKCS12
ssl.keystore.location=/certs/jks/host-admin/keystore.p12
ssl.keystore.password=$PW
ssl.endpoint.identification.algorithm=
EOF
echo "wrote $OUT/host/client.properties"
```

Also `mkdir -p "$OUT/host"` before the `cat`. Add that line above the heredoc.

- [ ] **Step 4: Dockerfile**

Create `clusters/step-ca/Dockerfile`:

```dockerfile
FROM smallstep/step-ca:0.26.1
USER root
RUN apk add --no-cache openssl openjdk11-jre-headless bash
COPY init/ /init/
RUN chmod +x /init/*.sh
# entrypoint is set per compose service
```

- [ ] **Step 5: Compose additions**

In `clusters/docker-compose.yml`, add two named volumes at the bottom:

```yaml
volumes:
  # ... existing volumes ...
  pki-root:
  pki-certs:
```

Add two services (leave them the only new services this task):

```yaml
  step-ca-init:
    build: ./step-ca
    image: kafka-lab/step-ca:local
    entrypoint: ["/init/step-ca-init.sh"]
    volumes:
      - pki-root:/step
    restart: "no"

  bootstrap-certs:
    build: ./step-ca
    image: kafka-lab/step-ca:local
    depends_on:
      step-ca-init:
        condition: service_completed_successfully
    entrypoint: ["/init/bootstrap-certs.sh"]
    volumes:
      - pki-root:/step:ro
      - pki-certs:/certs
      - ./step-ca/init/services.csv:/init/services.csv:ro
    restart: "no"
```

- [ ] **Step 6: Sanity boot**

```bash
chmod +x clusters/step-ca/init/*.sh
bash -n clusters/step-ca/init/step-ca-init.sh
bash -n clusters/step-ca/init/bootstrap-certs.sh
docker compose build step-ca-init
docker compose up -d step-ca-init bootstrap-certs
docker compose logs bootstrap-certs | tail -30
docker compose run --rm bootstrap-certs sh -c 'ls /certs/pem && ls /certs/jks && ls /certs/ca'
```

Expected: every service in `services.csv` has a `pem/<svc>` and `jks/<svc>` directory; `ca/ca-bundle.pem` exists.

- [ ] **Step 7: Commit**

```bash
git add clusters/step-ca clusters/docker-compose.yml
git commit -m "feat(pki): step-ca bootstrap + per-service leaf issuance (PEM + PKCS12)"
```

---

## Task 2: Controllers → SSL only

**Files:**
- Modify: `clusters/docker-compose.yml` (controller1/2/3 blocks + volume mounts)

**Interfaces:**
- Consumes: `pki-certs` from Task 1.
- Produces: controller quorum requires mTLS on `:9093`. Broker `KAFKA_CONTROLLER_QUORUM_VOTERS` unchanged.

- [ ] **Step 1: Update each controller block**

For each of controller1/2/3, set:

```yaml
    environment:
      # ... KRaft config unchanged ...
      KAFKA_LISTENERS: "CONTROLLER://:9093"
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: "CONTROLLER:SSL"
      KAFKA_CONTROLLER_LISTENER_NAMES: "CONTROLLER"
      KAFKA_SSL_KEYSTORE_LOCATION: "/certs/jks/controller<N>/keystore.p12"
      KAFKA_SSL_KEYSTORE_TYPE: "PKCS12"
      KAFKA_SSL_KEYSTORE_PASSWORD: "changeit-dev-only"
      KAFKA_SSL_TRUSTSTORE_LOCATION: "/certs/jks/controller<N>/truststore.p12"
      KAFKA_SSL_TRUSTSTORE_TYPE: "PKCS12"
      KAFKA_SSL_TRUSTSTORE_PASSWORD: "changeit-dev-only"
      KAFKA_SSL_CLIENT_AUTH: "required"
      KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
      KAFKA_SSL_PRINCIPAL_MAPPING_RULES: "RULE:^CN=(.*?),.*$$/$$1/L,DEFAULT"
    volumes:
      - pki-certs:/certs:ro
    depends_on:
      bootstrap-certs:
        condition: service_completed_successfully
```

(Note `$$` for compose escaping of `$1`.)

- [ ] **Step 2: Validate + boot**

```bash
docker compose config >/dev/null
docker compose up -d controller1 controller2 controller3
sleep 15
docker compose logs controller1 | grep -iE 'ssl|listener' | tail -20
docker compose ps controller1 controller2 controller3
```

Expected: all three healthy; log lines show SSL listener bound on 9093.

- [ ] **Step 3: Commit**

```bash
git add clusters/docker-compose.yml
git commit -m "feat(mtls): controller quorum switches to SSL:9093 (per-node cert)"
```

---

## Task 3: Brokers → SSL only (all four listeners) + authorizer + super.users + principal rule

**Files:**
- Modify: `clusters/docker-compose.yml` (broker1/2/3 blocks + host port map)

**Interfaces:**
- Consumes: `pki-certs`; controllers from Task 2.
- Produces: `broker<N>:9096` (in-network client mTLS), `broker<N>:9094` (inter-broker), host `localhost:9092|9093|9094` (external mTLS mapped to broker 29092).

- [ ] **Step 1: Update each broker block**

For each broker (N=1..3, HOST_PORT = 9092/9093/9094 for N=1/2/3):

```yaml
    environment:
      # remove: KAFKA_ALLOW_PLAINTEXT_LISTENER, any SASL_*, SCRAM, JAAS
      KAFKA_LISTENERS: "SSL://:9096,SSL_INTER://:9094,SSL_EXTERNAL://:29092"
      KAFKA_ADVERTISED_LISTENERS: "SSL://broker<N>:9096,SSL_INTER://broker<N>:9094,SSL_EXTERNAL://127.0.0.1:<HOST_PORT>"
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: "CONTROLLER:SSL,SSL:SSL,SSL_INTER:SSL,SSL_EXTERNAL:SSL"
      KAFKA_INTER_BROKER_LISTENER_NAME: "SSL_INTER"
      KAFKA_SSL_KEYSTORE_LOCATION: "/certs/jks/broker<N>/keystore.p12"
      KAFKA_SSL_KEYSTORE_TYPE: "PKCS12"
      KAFKA_SSL_KEYSTORE_PASSWORD: "changeit-dev-only"
      KAFKA_SSL_TRUSTSTORE_LOCATION: "/certs/jks/broker<N>/truststore.p12"
      KAFKA_SSL_TRUSTSTORE_TYPE: "PKCS12"
      KAFKA_SSL_TRUSTSTORE_PASSWORD: "changeit-dev-only"
      KAFKA_SSL_CLIENT_AUTH: "required"
      KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
      KAFKA_SSL_PRINCIPAL_MAPPING_RULES: "RULE:^CN=(.*?),.*$$/$$1/L,DEFAULT"
      KAFKA_AUTHORIZER_CLASS_NAME: "org.apache.kafka.metadata.authorizer.StandardAuthorizer"
      KAFKA_ALLOW_EVERYONE_IF_NO_ACL_FOUND: "false"
      KAFKA_SUPER_USERS: "User:admin;User:host-admin;User:broker1;User:broker2;User:broker3;User:controller1;User:controller2;User:controller3"
    ports:
      - "127.0.0.1:<HOST_PORT>:29092"
    volumes:
      - pki-certs:/certs:ro
    depends_on:
      bootstrap-certs:
        condition: service_completed_successfully
      controller1: {condition: service_healthy}
      controller2: {condition: service_healthy}
      controller3: {condition: service_healthy}
```

Update broker healthcheck to hit SSL. Replace the current `kafka-broker-api-versions` with:

```yaml
    healthcheck:
      test: ["CMD-SHELL", "kafka-broker-api-versions --bootstrap-server localhost:9096 --command-config /certs/pem/broker<N>-client.properties >/dev/null 2>&1 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 24
      start_period: 60s
```

Create per-broker client.properties inside the container via an inline entrypoint tweak OR reuse the host-admin one via a bind mount. Simplest: extend `bootstrap-certs.sh` (Task 1 file) — add at end:

```bash
for n in 1 2 3; do
  cp "$OUT/host/client.properties" "$OUT/pem/broker${n}-client.properties"
  sed -i "s|host-admin|broker${n}|g" "$OUT/pem/broker${n}-client.properties"
done
```

Add this snippet by editing `bootstrap-certs.sh` and commit in this task alongside the compose changes.

- [ ] **Step 2: Fresh boot**

```bash
docker compose down -v
docker compose up -d
sleep 60
docker compose ps broker1 broker2 broker3 controller1 controller2 controller3
docker compose logs broker1 | grep -iE 'ssl|listener|starting' | tail -30
```

Expected: brokers healthy, listener on 9096 only. Ports 9092/9095 do NOT exist.

- [ ] **Step 3: Smoke — plaintext refused**

```bash
docker compose exec broker1 sh -c 'ss -ltn | grep -E "9092|9095" || echo "no plaintext listeners"'
```

Expected: `no plaintext listeners`.

- [ ] **Step 4: Commit**

```bash
git add clusters/docker-compose.yml clusters/step-ca/init/bootstrap-certs.sh
git commit -m "feat(mtls): brokers SSL-only listeners + StandardAuthorizer + principal mapping"
```

---

## Task 4: `acl-bootstrap` one-shot

**Files:**
- Create: `clusters/kafka/acl-bootstrap.sh`
- Modify: `clusters/docker-compose.yml`

**Interfaces:**
- Consumes: brokers healthy (Task 3), admin cert from Task 1.
- Produces: ACLs applied (idempotent — safe to re-run).

- [ ] **Step 1: Write the script**

Create `clusters/kafka/acl-bootstrap.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

BS="${BOOTSTRAP:-broker1:9096}"
CC="/certs/admin.properties"

# build admin client.properties from admin PEM material
cat > "$CC" <<EOF
security.protocol=SSL
ssl.truststore.type=PKCS12
ssl.truststore.location=/certs/jks/admin/truststore.p12
ssl.truststore.password=changeit-dev-only
ssl.keystore.type=PKCS12
ssl.keystore.location=/certs/jks/admin/keystore.p12
ssl.keystore.password=changeit-dev-only
ssl.endpoint.identification.algorithm=
EOF

ACL="kafka-acls --bootstrap-server $BS --command-config $CC"

# each command is idempotent — Kafka returns "already exists" silently
$ACL --add --producer --topic events --allow-principal User:loadgen
$ACL --add --consumer --topic events --group connect-s3-sink --allow-principal User:kafka-connect
for t in __connect-configs __connect-offsets __connect-status; do
  $ACL --add --allow-principal User:kafka-connect --operation All --topic "$t"
done
$ACL --add --allow-principal User:kafka-connect --operation DescribeConfigs --cluster
$ACL --add --allow-principal User:kafka-connect --operation Create --cluster

$ACL --add --allow-principal User:schema-registry --operation All --topic _schemas
$ACL --add --allow-principal User:schema-registry --operation All --group schema-registry

$ACL --add --allow-principal User:akhq --operation Describe --cluster
$ACL --add --allow-principal User:akhq --operation Read --topic '*'
$ACL --add --allow-principal User:akhq --operation Describe --topic '*'
$ACL --add --allow-principal User:akhq --operation Read --group '*'
$ACL --add --allow-principal User:akhq --operation Describe --group '*'

$ACL --add --allow-principal User:kminion --operation Describe --cluster
$ACL --add --allow-principal User:kminion --operation Describe --topic '*'
$ACL --add --allow-principal User:kminion --operation Describe --group '*'

for op in Describe DescribeConfigs Alter AlterConfigs; do
  $ACL --add --allow-principal User:cruise-control --operation "$op" --cluster
done
$ACL --add --allow-principal User:cruise-control --operation Describe --topic '*'
$ACL --add --allow-principal User:cruise-control --operation Read --topic '*'

$ACL --add --allow-principal User:mcp-kafka --operation Describe --cluster
$ACL --add --allow-principal User:mcp-kafka --operation Read --topic '*'
$ACL --add --allow-principal User:mcp-kafka --operation Describe --topic '*'
$ACL --add --allow-principal User:mcp-kafka --operation Read --group 'mcp-tail-*'

echo "ACL bootstrap complete"
```

- [ ] **Step 2: Compose service**

Add:

```yaml
  acl-bootstrap:
    image: apache/kafka:3.8.0
    depends_on:
      broker1: {condition: service_healthy}
      broker2: {condition: service_healthy}
      broker3: {condition: service_healthy}
    entrypoint: ["/bin/bash", "/opt/acl-bootstrap.sh"]
    volumes:
      - ./kafka/acl-bootstrap.sh:/opt/acl-bootstrap.sh:ro
      - pki-certs:/certs:ro
    restart: "no"
```

- [ ] **Step 3: Run + verify**

```bash
chmod +x clusters/kafka/acl-bootstrap.sh
bash -n clusters/kafka/acl-bootstrap.sh
docker compose up -d acl-bootstrap
docker compose logs acl-bootstrap | tail -30
docker compose exec broker1 kafka-acls --bootstrap-server broker1:9096 --command-config /certs/admin.properties --list | head -40
```

Expected: `ACL bootstrap complete`; ACL list shows expected principals.

- [ ] **Step 4: Commit**

```bash
git add clusters/kafka/acl-bootstrap.sh clusters/docker-compose.yml
git commit -m "feat(mtls): acl-bootstrap one-shot seeds least-privilege ACLs"
```

---

## Task 5: schema-registry mTLS (Kafka client + optional REST client-cert)

**Files:**
- Modify: `services/schema-registry/*` (config template or entrypoint) and/or `clusters/docker-compose.yml`

**Interfaces:**
- Consumes: brokers + ACL for `User:schema-registry`.
- Produces: SR reachable at `http://schema-registry:8081` (HTTP — REST client-cert on the SR side is OPTIONAL and can stay HTTP if AKHQ has integration issues; the Kafka client side is mandatory).

- [ ] **Step 1: Compose env for SR**

Add/replace envs:

```yaml
      SCHEMA_REGISTRY_KAFKASTORE_SECURITY_PROTOCOL: "SSL"
      SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS: "SSL://broker1:9096,SSL://broker2:9096,SSL://broker3:9096"
      SCHEMA_REGISTRY_KAFKASTORE_SSL_KEYSTORE_LOCATION: "/certs/jks/schema-registry/keystore.p12"
      SCHEMA_REGISTRY_KAFKASTORE_SSL_KEYSTORE_TYPE: "PKCS12"
      SCHEMA_REGISTRY_KAFKASTORE_SSL_KEYSTORE_PASSWORD: "changeit-dev-only"
      SCHEMA_REGISTRY_KAFKASTORE_SSL_TRUSTSTORE_LOCATION: "/certs/jks/schema-registry/truststore.p12"
      SCHEMA_REGISTRY_KAFKASTORE_SSL_TRUSTSTORE_TYPE: "PKCS12"
      SCHEMA_REGISTRY_KAFKASTORE_SSL_TRUSTSTORE_PASSWORD: "changeit-dev-only"
      SCHEMA_REGISTRY_KAFKASTORE_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM: ""
    volumes:
      - pki-certs:/certs:ro
    depends_on:
      acl-bootstrap:
        condition: service_completed_successfully
```

- [ ] **Step 2: Restart + smoke**

```bash
docker compose up -d schema-registry
sleep 15
docker compose logs schema-registry | tail -20
docker compose exec schema-registry curl -sf http://localhost:8081/subjects
```

Expected: `[]` (empty subjects list) or existing list — no error.

- [ ] **Step 3: Commit**

```bash
git add clusters/docker-compose.yml
git commit -m "feat(mtls): schema-registry uses SSL client to brokers"
```

---

## Task 6: kafka-connect mTLS + REST HTTPS client-cert (removes PR 8 basic-auth)

**Files:**
- Modify: `services/kafka-connect/entrypoint-secrets.sh` (or replace with `entrypoint-ssl.sh`)
- Modify: `clusters/docker-compose.yml`
- Delete: `services/kafka-connect/rest-auth.jaas` (PR 8 artefact)

**Interfaces:**
- Consumes: acl-bootstrap done (User:kafka-connect).
- Produces: `https://kafka-connect:8083` requires client cert. Kafka client SSL to brokers.

- [ ] **Step 1: Rewrite entrypoint**

Replace `services/kafka-connect/entrypoint-secrets.sh` body with:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Kafka client SSL
export CONNECT_SECURITY_PROTOCOL=SSL
export CONNECT_SSL_KEYSTORE_LOCATION=/certs/jks/kafka-connect/keystore.p12
export CONNECT_SSL_KEYSTORE_TYPE=PKCS12
export CONNECT_SSL_KEYSTORE_PASSWORD=changeit-dev-only
export CONNECT_SSL_TRUSTSTORE_LOCATION=/certs/jks/kafka-connect/truststore.p12
export CONNECT_SSL_TRUSTSTORE_TYPE=PKCS12
export CONNECT_SSL_TRUSTSTORE_PASSWORD=changeit-dev-only
export CONNECT_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""

# Producer + consumer inherit via prefix
for prefix in CONNECT_PRODUCER_ CONNECT_CONSUMER_; do
  eval "export ${prefix}SECURITY_PROTOCOL=SSL"
  eval "export ${prefix}SSL_KEYSTORE_LOCATION=/certs/jks/kafka-connect/keystore.p12"
  eval "export ${prefix}SSL_KEYSTORE_TYPE=PKCS12"
  eval "export ${prefix}SSL_KEYSTORE_PASSWORD=changeit-dev-only"
  eval "export ${prefix}SSL_TRUSTSTORE_LOCATION=/certs/jks/kafka-connect/truststore.p12"
  eval "export ${prefix}SSL_TRUSTSTORE_TYPE=PKCS12"
  eval "export ${prefix}SSL_TRUSTSTORE_PASSWORD=changeit-dev-only"
  eval "export ${prefix}SSL_ENDPOINT_IDENTIFICATION_ALGORITHM="
done

# REST listener HTTPS + client cert required
export CONNECT_LISTENERS="https://0.0.0.0:8083"
export CONNECT_LISTENERS_HTTPS_SSL_KEYSTORE_LOCATION=/certs/jks/kafka-connect/keystore.p12
export CONNECT_LISTENERS_HTTPS_SSL_KEYSTORE_TYPE=PKCS12
export CONNECT_LISTENERS_HTTPS_SSL_KEYSTORE_PASSWORD=changeit-dev-only
export CONNECT_LISTENERS_HTTPS_SSL_TRUSTSTORE_LOCATION=/certs/jks/kafka-connect/truststore.p12
export CONNECT_LISTENERS_HTTPS_SSL_TRUSTSTORE_TYPE=PKCS12
export CONNECT_LISTENERS_HTTPS_SSL_TRUSTSTORE_PASSWORD=changeit-dev-only
export CONNECT_LISTENERS_HTTPS_SSL_CLIENT_AUTH=required

# PR 8 basic-auth env: intentionally NOT set. Remove any leftover.
unset CONNECT_REST_EXTENSION_CLASSES || true
unset KAFKA_OPTS_BASIC_AUTH || true

exec "$@"
```

- [ ] **Step 2: Delete PR 8 JAAS file**

```bash
git rm services/kafka-connect/rest-auth.jaas 2>/dev/null || rm -f services/kafka-connect/rest-auth.jaas
```

- [ ] **Step 3: Compose adjustments**

In `clusters/docker-compose.yml` for `kafka-connect`:

```yaml
    volumes:
      - pki-certs:/certs:ro
      - ./kafka-connect/entrypoint-secrets.sh:/entrypoint-secrets.sh:ro   # if already mounted, keep
    depends_on:
      acl-bootstrap:
        condition: service_completed_successfully
      schema-registry:
        condition: service_healthy
```

Remove any PR 8 basic-auth env vars from the block. Update healthcheck to hit HTTPS with a client cert (mount host-admin cert):

```yaml
    healthcheck:
      test: ["CMD-SHELL", "curl --cacert /certs/ca/ca-bundle.pem --cert /certs/pem/host-admin/tls.crt --key /certs/pem/host-admin/tls.key -sf https://localhost:8083/connectors >/dev/null || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 12
      start_period: 30s
```

- [ ] **Step 4: Restart + verify**

```bash
docker compose up -d kafka-connect
sleep 30
docker compose ps kafka-connect
docker compose exec kafka-connect curl --cacert /certs/ca/ca-bundle.pem \
  --cert /certs/pem/host-admin/tls.crt --key /certs/pem/host-admin/tls.key \
  -sf https://localhost:8083/connectors
docker compose exec kafka-connect curl --cacert /certs/ca/ca-bundle.pem \
  -sf https://localhost:8083/connectors 2>&1 || echo "OK: rejected without client cert"
```

Expected: first curl returns JSON; second fails with SSL handshake error.

- [ ] **Step 5: Commit**

```bash
git add services/kafka-connect/entrypoint-secrets.sh clusters/docker-compose.yml
git rm --cached -q services/kafka-connect/rest-auth.jaas 2>/dev/null || true
git add -u
git commit -m "feat(mtls): kafka-connect Kafka+REST mTLS; removes PR 8 basic-auth"
```

---

## Task 7: akhq mTLS

**Files:**
- Modify: `services/akhq/application.yml`
- Modify: `clusters/docker-compose.yml`

**Interfaces:** consumes ACL for `User:akhq`. Produces AKHQ UI showing cluster online.

- [ ] **Step 1: application.yml**

In the cluster block, add under `properties:`:

```yaml
akhq:
  connections:
    kafka-lab:
      properties:
        bootstrap.servers: "broker1:9096,broker2:9096,broker3:9096"
        security.protocol: SSL
        ssl.keystore.type: PKCS12
        ssl.keystore.location: /certs/jks/akhq/keystore.p12
        ssl.keystore.password: changeit-dev-only
        ssl.truststore.type: PKCS12
        ssl.truststore.location: /certs/jks/akhq/truststore.p12
        ssl.truststore.password: changeit-dev-only
        ssl.endpoint.identification.algorithm: ""
      schema-registry:
        url: "http://schema-registry:8081"
```

- [ ] **Step 2: Compose**

Add:

```yaml
    volumes:
      - pki-certs:/certs:ro
      - ./akhq/application.yml:/app/application.yml:ro
    depends_on:
      acl-bootstrap:
        condition: service_completed_successfully
```

- [ ] **Step 3: Restart + smoke**

```bash
docker compose up -d akhq
sleep 20
curl -sf http://localhost:8080/api/kafka-lab/topic | head -c 200
```

Expected: JSON topic list.

- [ ] **Step 4: Commit**

```bash
git add services/akhq/application.yml clusters/docker-compose.yml
git commit -m "feat(mtls): akhq connects to brokers via SSL"
```

---

## Task 8: kminion mTLS

**Files:**
- Modify: `services/kminion/kminion.yaml`
- Modify: `clusters/docker-compose.yml`

- [ ] **Step 1: kminion.yaml**

Replace any sasl block; ensure kafka block reads:

```yaml
kafka:
  brokers:
    - broker1:9096
    - broker2:9096
    - broker3:9096
  tls:
    enabled: true
    ca_filepath: /certs/ca/ca-bundle.pem
    cert_filepath: /certs/pem/kminion/tls.crt
    key_filepath: /certs/pem/kminion/tls.key
    insecure_skip_tls_verify: false
```

- [ ] **Step 2: Compose**

Add `volumes: - pki-certs:/certs:ro`; add `depends_on: acl-bootstrap: {condition: service_completed_successfully}`.

- [ ] **Step 3: Restart + verify**

```bash
docker compose up -d kminion
sleep 15
docker compose logs kminion | tail -10
curl -sf http://kminion:8080/metrics || docker compose exec prometheus wget -qO- http://kminion:8080/metrics | head
```

Expected: kminion metrics served; `up{job="kminion"} == 1` in Prometheus later.

- [ ] **Step 4: Commit**

```bash
git add services/kminion/kminion.yaml clusters/docker-compose.yml
git commit -m "feat(mtls): kminion TLS client to brokers (SASL removed)"
```

---

## Task 9: cruise-control mTLS

**Files:**
- Modify: `services/cruise-control/config/cruisecontrol.properties`
- Modify: `clusters/docker-compose.yml`

- [ ] **Step 1: cruisecontrol.properties**

Append/replace:

```properties
bootstrap.servers=broker1:9096,broker2:9096,broker3:9096
security.protocol=SSL
ssl.keystore.type=PKCS12
ssl.keystore.location=/certs/jks/cruise-control/keystore.p12
ssl.keystore.password=changeit-dev-only
ssl.truststore.type=PKCS12
ssl.truststore.location=/certs/jks/cruise-control/truststore.p12
ssl.truststore.password=changeit-dev-only
ssl.endpoint.identification.algorithm=
```

- [ ] **Step 2: Compose**

Add `volumes: - pki-certs:/certs:ro`; add `depends_on: acl-bootstrap: {condition: service_completed_successfully}`.

- [ ] **Step 3: Restart + smoke**

```bash
docker compose up -d cruise-control
sleep 45
curl -sf 'http://localhost:9095/kafkacruisecontrol/state?substates=analyzer,anomaly_detector,executor' | head -c 400
```

Expected: JSON state response.

- [ ] **Step 4: Commit**

```bash
git add services/cruise-control clusters/docker-compose.yml
git commit -m "feat(mtls): cruise-control SSL to brokers"
```

---

## Task 10: loadgen mTLS

**Files:**
- Modify: `services/loadgen/app/loadgen.py`
- Modify: `clusters/docker-compose.yml`

- [ ] **Step 1: loadgen.py**

Locate the `KafkaProducer(...)` construction. Add these kwargs (env-driven):

```python
producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP,
    security_protocol=os.getenv("KAFKA_SECURITY_PROTOCOL", "SSL"),
    ssl_cafile=os.getenv("KAFKA_SSL_CAFILE", "/certs/ca/ca-bundle.pem"),
    ssl_certfile=os.getenv("KAFKA_SSL_CERTFILE", "/certs/pem/loadgen/tls.crt"),
    ssl_keyfile=os.getenv("KAFKA_SSL_KEYFILE", "/certs/pem/loadgen/tls.key"),
    ssl_check_hostname=False,
    value_serializer=lambda v: json.dumps(v).encode(),
    key_serializer=lambda k: k.encode(),
    linger_ms=5,
    acks="all",
)
```

Keep any existing kwargs the current constructor uses; do not remove `linger_ms`/`acks` if the file already sets them differently — match the existing style.

- [ ] **Step 2: Compose**

Update `loadgen` (or the current `loadgen-direct` if the branch has PR-10 renames — check with `grep -n loadgen clusters/docker-compose.yml`):

```yaml
    environment:
      KAFKA_BOOTSTRAP_SERVERS: "broker1:9096,broker2:9096,broker3:9096"
      KAFKA_SECURITY_PROTOCOL: "SSL"
    volumes:
      - pki-certs:/certs:ro
    depends_on:
      acl-bootstrap:
        condition: service_completed_successfully
```

- [ ] **Step 3: Restart + verify produce**

```bash
docker compose build loadgen
docker compose up -d loadgen
sleep 15
docker compose logs loadgen | tail -20
docker compose exec broker1 kafka-console-consumer --bootstrap-server broker1:9096 --command-config /certs/admin.properties --topic events --max-messages 1 --timeout-ms 20000
```

Expected: one message consumed.

- [ ] **Step 4: Commit**

```bash
git add services/loadgen/app/loadgen.py clusters/docker-compose.yml
git commit -m "feat(mtls): loadgen SSL producer"
```

---

## Task 11: mcp-kafka mTLS

**Files:**
- Modify: `services/mcp-kafka/app/server.py`
- Modify: `clusters/docker-compose.yml`

- [ ] **Step 1: server.py**

Where `KafkaConsumer` / `KafkaProducer` is built for tools like `tail_topic`, add matching SSL kwargs (mirror Task 10 pattern with `/certs/pem/mcp-kafka/*`).

- [ ] **Step 2: Compose**

```yaml
    environment:
      KAFKA_BOOTSTRAP: "broker1:9096,broker2:9096,broker3:9096"
      KAFKA_SECURITY_PROTOCOL: "SSL"
      KAFKA_SSL_CAFILE: "/certs/ca/ca-bundle.pem"
      KAFKA_SSL_CERTFILE: "/certs/pem/mcp-kafka/tls.crt"
      KAFKA_SSL_KEYFILE: "/certs/pem/mcp-kafka/tls.key"
    volumes:
      - pki-certs:/certs:ro
    depends_on:
      acl-bootstrap:
        condition: service_completed_successfully
```

- [ ] **Step 3: Restart + smoke**

```bash
docker compose up -d mcp-kafka
sleep 15
docker compose logs mcp-kafka | tail -20
```

Expected: no SSL errors; MCP process starts.

- [ ] **Step 4: Commit**

```bash
git add services/mcp-kafka/app/server.py clusters/docker-compose.yml
git commit -m "feat(mtls): mcp-kafka SSL client"
```

---

## Task 12: `tools/kafka.sh` host wrapper

**Files:**
- Modify: `tools/kafka.sh`

**Interfaces:**
- Consumes: host cert at `clusters/certs-mirror/host-admin/*` — export via a `docker compose run --rm bootstrap-certs sh -c 'tar -C /certs -cf - .' | tar -C clusters/certs-mirror -xf -` one-liner (Step 1).
- Produces: host CLI that talks to `localhost:9092|9093|9094` over SSL.

- [ ] **Step 1: Mirror certs to host**

```bash
mkdir -p clusters/certs-mirror
docker compose run --rm bootstrap-certs sh -c 'tar -C /certs -cf - ca pem/host-admin jks/host-admin host' | tar -C clusters/certs-mirror -xf -
```

Add `clusters/certs-mirror/` to `.gitignore` (verify with `grep -q certs-mirror .gitignore || echo certs-mirror >> .gitignore`).

- [ ] **Step 2: Update `tools/kafka.sh`**

At the top (env resolution section), add:

```bash
: "${KAFKA_BOOTSTRAP_LOCAL:=localhost:9092}"
: "${KAFKA_CLIENT_CONFIG:=$(git rev-parse --show-toplevel)/clusters/certs-mirror/host/client.properties}"
```

Ensure `client.properties` inside `certs-mirror/host/` has absolute paths — rewrite in this step:

```bash
sed -i.bak "s|/certs|$(git rev-parse --show-toplevel)/clusters/certs-mirror|g" clusters/certs-mirror/host/client.properties
rm clusters/certs-mirror/host/client.properties.bak
```

Every wrapper subcommand invocation adds `--command-config "$KAFKA_CLIENT_CONFIG"` and `--bootstrap-server "$KAFKA_BOOTSTRAP_LOCAL"`.

- [ ] **Step 3: Smoke**

```bash
bash -n tools/kafka.sh
tools/kafka.sh topic-list
```

Expected: topic list including `events`, `_schemas`.

- [ ] **Step 4: Commit**

```bash
git add tools/kafka.sh .gitignore
git commit -m "feat(mtls): tools/kafka.sh SSL wrapper using host-admin cert"
```

---

## Task 13: `tools/mtls-verify.sh` integration proof

**Files:**
- Create: `tools/mtls-verify.sh`

- [ ] **Step 1: Write script**

Create `tools/mtls-verify.sh` implementing §8.2 of the spec (9 assertions). Key snippets:

```bash
#!/usr/bin/env bash
set -euo pipefail

check() { echo "== $1"; shift; "$@" && echo "  OK" || { echo "  FAIL"; exit 1; }; }

check "chain verify (loadgen leaf)" \
  docker compose run --rm bootstrap-certs sh -c \
  'openssl verify -CAfile /certs/ca/ca-bundle.pem /certs/pem/loadgen/tls.crt >/dev/null'

check "no plaintext listener on broker1" \
  bash -c '! docker compose exec broker1 ss -ltn | grep -qE ":9092|:9095"'

check "unauth client refused" \
  bash -c '
    docker compose exec broker1 sh -c "kafka-topics --bootstrap-server broker1:9096 --list 2>&1" \
      | grep -qE "SSL|Handshake|SASL|Authentication" '

check "ACL enforced (loadgen denied describe _schemas)" \
  bash -c '
    docker compose run --rm -v pki-certs:/certs:ro \
      -e KAFKA_HEAP_OPTS=-Xmx128m apache/kafka:3.8.0 \
      sh -c "cat > /tmp/loadgen.properties <<EOF
security.protocol=SSL
ssl.truststore.type=PKCS12
ssl.truststore.location=/certs/jks/loadgen/truststore.p12
ssl.truststore.password=changeit-dev-only
ssl.keystore.type=PKCS12
ssl.keystore.location=/certs/jks/loadgen/keystore.p12
ssl.keystore.password=changeit-dev-only
ssl.endpoint.identification.algorithm=
EOF
kafka-topics --bootstrap-server broker1:9096 --command-config /tmp/loadgen.properties --describe --topic _schemas 2>&1" \
    | grep -qE "TOPIC_AUTHORIZATION_FAILED|not authorized" '

check "host wrapper works" \
  bash -c 'tools/kafka.sh topic-list | grep -q events'

check "connect REST needs client cert" \
  bash -c '
    ! docker compose exec kafka-connect curl -sf --cacert /certs/ca/ca-bundle.pem https://localhost:8083/connectors '

check "connect REST OK with cert" \
  bash -c '
    docker compose exec kafka-connect curl -sf --cacert /certs/ca/ca-bundle.pem \
      --cert /certs/pem/host-admin/tls.crt --key /certs/pem/host-admin/tls.key \
      https://localhost:8083/connectors | grep -q "\["'

echo "ALL mTLS CHECKS PASS"
```

- [ ] **Step 2: Run**

```bash
chmod +x tools/mtls-verify.sh
bash -n tools/mtls-verify.sh
tools/mtls-verify.sh
```

Expected final line: `ALL mTLS CHECKS PASS`.

- [ ] **Step 3: Commit**

```bash
git add tools/mtls-verify.sh
git commit -m "test(mtls): mtls-verify.sh — 7 assertions covering chain, listeners, ACL, REST"
```

---

## Task 14: Cert-expiry observability (blackbox + rules + dashboard)

**Files:**
- Modify: `blackbox/blackbox.yml`
- Modify: `prometheus/prometheus.yml`
- Create: `prometheus/rules/mtls.rules.yml`
- Create: `grafana/dashboards/kafka-security.json`

- [ ] **Step 1: Blackbox module**

Add to `blackbox/blackbox.yml` under `modules:`:

```yaml
  ssl_cert_expiry:
    prober: tcp
    timeout: 5s
    tcp:
      tls: true
      tls_config:
        insecure_skip_verify: true
```

- [ ] **Step 2: Prometheus job**

Append to `prometheus/prometheus.yml`:

```yaml
  - job_name: cert_expiry
    scrape_interval: 60s
    metrics_path: /probe
    params:
      module: [ssl_cert_expiry]
    static_configs:
      - targets:
          - broker1:9096
          - broker2:9096
          - broker3:9096
          - controller1:9093
          - controller2:9093
          - controller3:9093
          - kafka-connect:8083
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115
```

Also add `- "rules/mtls.rules.yml"` to `rule_files:`.

- [ ] **Step 3: Rules**

Create `prometheus/rules/mtls.rules.yml`:

```yaml
groups:
  - name: mtls.recording
    interval: 30s
    rules:
      - record: slo:cert_days_until_expiry
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400

  - name: mtls.alerts
    rules:
      - alert: KafkaCertExpiringSoon
        expr: slo:cert_days_until_expiry < 14
        for: 30m
        labels: {severity: warning, cluster: local}
        annotations:
          summary: "{{ $labels.instance }} cert expires in < 14d"
      - alert: KafkaCertExpired
        expr: slo:cert_days_until_expiry < 0
        for: 5m
        labels: {severity: critical, cluster: local}
        annotations:
          summary: "{{ $labels.instance }} cert EXPIRED"
      - alert: KafkaAuthFailureBurst
        expr: sum(rate({container_name=~"broker.*"} |= "TOPIC_AUTHORIZATION_FAILED" [5m])) > 1
        for: 5m
        labels: {severity: warning, cluster: local}
        annotations:
          summary: "Kafka authorization failures > 1/s for 5m — misconfig or attack"
```

Note: the `KafkaAuthFailureBurst` uses LogQL — actually a Loki alert. If existing Prometheus doesn't support Loki queries, put this alert in the Loki ruler config instead. Check `docker compose config | grep -A5 loki` to see if a Loki ruler exists; adapt.

- [ ] **Step 4: Dashboard**

Create `grafana/dashboards/kafka-security.json` with two panels: expiry stat per target, and auth-failure log rate (via Loki datasource if available; otherwise omit and note in commit).

- [ ] **Step 5: Validate + restart**

```bash
docker run --rm -v "$PWD/prometheus:/etc/prometheus" prom/prometheus:latest \
  promtool check rules /etc/prometheus/rules/mtls.rules.yml
docker compose up -d prometheus blackbox-exporter grafana
sleep 20
curl -sf 'http://localhost:9090/api/v1/query?query=probe_ssl_earliest_cert_expiry' | jq '.data.result | length'
```

Expected: non-zero result count.

- [ ] **Step 6: Commit**

```bash
git add blackbox/blackbox.yml prometheus/prometheus.yml prometheus/rules/mtls.rules.yml grafana/dashboards/kafka-security.json
git commit -m "feat(observability): cert-expiry blackbox probes + alerts + security dashboard"
```

---

## Task 15: Chaos scenarios `cert-expiry-warn` + `bad-cert-rejected`

**Files:**
- Modify: `tools/chaos-run.sh`
- Modify: `tools/README-chaos.md`

- [ ] **Step 1: Add scenarios**

Append to `tools/chaos-run.sh`:

```bash
scenario_cert_expiry_warn() {
  log "issue short-lived cert for loadgen (60s)"
  docker compose run --rm -e OVERRIDE_NOT_AFTER=1m bootstrap-certs sh -c '
    step ca certificate loadgen /certs/pem/loadgen/tls.crt /certs/pem/loadgen/tls.key \
      --san loadgen --provisioner admin \
      --provisioner-password-file /step/secrets/password \
      --ca-url https://step-ca:9000 --root /step/certs/root_ca.crt \
      --not-after 1m --force'
  docker compose restart loadgen
  wait_for_alert "KafkaCertExpired" 240
  log "restore normal cert"
  docker compose run --rm bootstrap-certs
  docker compose restart loadgen
}

scenario_bad_cert_rejected() {
  log "mint off-CA cert"
  docker run --rm -v pki-certs:/certs alpine/openssl \
    sh -c 'openssl req -x509 -newkey rsa:2048 -nodes -keyout /certs/pem/loadgen/tls.key -out /certs/pem/loadgen/tls.crt -days 1 -subj /CN=loadgen'
  docker compose restart loadgen
  sleep 30
  docker compose logs loadgen | grep -qE 'SSL|Handshake|Authentication' && log "loadgen refused" || { log "FAIL: loadgen not refused"; exit 1; }
  docker compose run --rm bootstrap-certs
  docker compose restart loadgen
}
```

Register in scenario list (mirror existing pattern).

- [ ] **Step 2: README-chaos.md**

Add:

```
| cert-expiry-warn | leaf 1m validity → alert fires + recovery | KafkaCertExpired | 4m |
| bad-cert-rejected | off-CA cert → SSL handshake refused | log-based (SSLHandshakeException) | 1m |
```

- [ ] **Step 3: Syntax + run**

```bash
bash -n tools/chaos-run.sh
SCENARIOS="cert-expiry-warn bad-cert-rejected" tools/chaos-run.sh
```

Expected: both PASS.

- [ ] **Step 4: Commit**

```bash
git add tools/chaos-run.sh tools/README-chaos.md
git commit -m "test(chaos): cert-expiry-warn + bad-cert-rejected scenarios"
```

---

## Task 16: `tools/cert-rotate.sh` + docs

**Files:**
- Create: `tools/cert-rotate.sh`
- Modify: `04-SECURITY-GUARDRAILS.md`
- Modify: `02-INTEGRATION-ARCHITECTURE.md`
- Modify: `03-DATA-FLOW-ARCHITECTURE.md`

- [ ] **Step 1: cert-rotate.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
svc="${1:?usage: cert-rotate.sh <svc>}"
docker compose run --rm bootstrap-certs sh -c "
  rm -f /certs/pem/$svc/tls.crt /certs/pem/$svc/tls.key /certs/jks/$svc/keystore.p12
  /init/bootstrap-certs.sh
"
docker compose restart "$svc"
echo "rotated $svc"
```

- [ ] **Step 2: 04-SECURITY-GUARDRAILS.md**

Rewrite §2 listener matrix table with post-PR-9 state (only SSL rows). Add §2.1 subsection: PKI layout, cert lifetimes, super-user list, rotation procedure (pointer to `cert-rotate.sh`).

- [ ] **Step 3: 02-INTEGRATION-ARCHITECTURE.md**

In §4 startup ordering, prepend: `0. step-ca-init → bootstrap-certs.` Update chain to add `acl-bootstrap` after brokers, before schema-registry.

Add §7.x subsection "PR 9 Runbook":
- Fresh boot: `docker compose down -v && docker compose up -d`.
- Verify: `tools/mtls-verify.sh`.
- Rotate: `tools/cert-rotate.sh <svc>`.
- Chaos: `SCENARIOS="cert-expiry-warn bad-cert-rejected" tools/chaos-run.sh`.

- [ ] **Step 4: 03-DATA-FLOW-ARCHITECTURE.md**

Append 4 failure rows per spec §7:

```
| Leaf cert expired | client SSL handshake fails | that svc offline | slo:cert_days_until_expiry < 0 |
| Intermediate CA expired | ALL clients fail handshake | full data plane outage | slo:cert_days_until_expiry < 0 (any target) |
| ACL missing rule | authenticated, ops rejected | that op blocked | KafkaAuthFailureBurst |
| step-ca volume corrupt | bootstrap-certs cannot issue new leaves | full stack down at fresh boot | brokers non-healthy |
```

- [ ] **Step 5: Commit**

```bash
chmod +x tools/cert-rotate.sh
git add tools/cert-rotate.sh 04-SECURITY-GUARDRAILS.md 02-INTEGRATION-ARCHITECTURE.md 03-DATA-FLOW-ARCHITECTURE.md
git commit -m "docs(mtls): PR 9 runbook, listener matrix, failure rows, rotation helper"
```

---

## Task 17: Push + open PR

**Files:** none.

- [ ] **Step 1: Push**

```bash
git push -u origin pr9-mtls-foundation
```

- [ ] **Step 2: PR**

```bash
gh pr create --base main --title "feat(security): PR 9 — mTLS foundation (broker+controller+clients+ACLs, replaces PR 8 basic-auth)" --body "$(cat <<'EOF'
## Summary
- step-ca Root(10y)+Intermediate(5y); 90d leaves per service; PEM + PKCS12.
- Brokers + controllers: SSL-only listeners, StandardAuthorizer, least-privilege ACLs, default deny.
- Every client (connect, schema-registry, akhq, kminion, cruise-control, loadgen, mcp-kafka) uses SSL.
- Connect REST: HTTPS with client-cert auth. PR 8 basic-auth REMOVED.
- Host CLI wrapper `tools/kafka.sh` uses host-admin cert.
- Cert-expiry blackbox alerts at 14d/expired.

## Test plan
- [x] `tools/mtls-verify.sh` — 7 assertions PASS.
- [x] `SCENARIOS="cert-expiry-warn bad-cert-rejected" tools/chaos-run.sh` PASS.
- [x] `docker compose down -v && docker compose up -d` — cold boot green.
- [x] AKHQ, Grafana, Cruise Control UIs reachable.

## Breaking
- SCRAM users, PR8 basic-auth removed. Any external doc/tool must adopt certs.
EOF
)"
```

---

## Self-Review Log

- Spec §1 goals 1–7: T2/T3 (goal 1), T3 (2), T3+T4 (3), T1 (4), T1 (5), T6 (6), T14 (7).
- Spec §3 services: step-ca-init/bootstrap-certs/cert-issuer image (T1), acl-bootstrap (T4). Controller/broker changes (T2/T3).
- Spec §4 PKI layout: T1.
- Spec §5 principals + ACLs: T4.
- Spec §6 observability: T14.
- Spec §7 failure map: T16 Step 4.
- Spec §8 testing: T13 (integration), T15 (chaos).
- Spec §9 file changes: covered across T1–T16.
- Spec §11 open questions: image tags pinned in Dockerfile (T1) and compose (T4); cruise-control PKCS12 assumption — mitigated in T9 (if it fails, replace `.p12` with JKS via keytool one-liner); schema-registry AKHQ Avro rendering — validated at T7 Step 3.
- No `TBD`/`TODO`/vague-error-handling strings.
- Symbol consistency: `changeit-dev-only`, `/certs/jks/<svc>`, `/certs/pem/<svc>`, `RULE:^CN=(.*?),.*$/$1/L,DEFAULT`, super.users enumeration — used identically across all tasks.
- Note on Loki alert (T14 Step 3): if the stack does not have a Loki ruler wired, keep only the two cert-expiry alerts and note this in the T14 commit message. Do not add a broken Prometheus alert.
