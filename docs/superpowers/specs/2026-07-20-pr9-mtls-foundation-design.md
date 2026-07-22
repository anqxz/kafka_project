# PR 9 — mTLS Foundation (broker + controller + all clients + ACLs)

- **Status**: Approved (design)
- **Date**: 2026-07-20
- **Scope**: Full mTLS replacement — PLAINTEXT and SASL_* listeners removed. StandardAuthorizer + ACLs default-deny.
- **Related PRs**: replaces PR 8 basic-auth on Connect REST (Connect REST becomes client-cert authenticated). Enables PR 10 (Kroxylicious governance profile) to inherit mTLS on its upstream.
- **Related docs**: `04-SECURITY-GUARDRAILS.md` §2 (listener matrix), `02-INTEGRATION-ARCHITECTURE.md` §4 (startup ordering), `03-DATA-FLOW-ARCHITECTURE.md` §6 (failure map).

## 1. Goals

1. Every Kafka network path — client↔broker, inter-broker, controller quorum, host↔broker external — uses mTLS. No plaintext, no SASL, no SASL_SSL.
2. Kafka principals derived from cert CN via `ssl.principal.mapping.rules`. Zero custom code.
3. `StandardAuthorizer` (KRaft-native) enabled with least-privilege ACLs per service principal, `allow.everyone.if.no.acl.found=false`.
4. Root CA (10y) + Intermediate CA (5y) via step-ca. Leaf certs 90d, manual rotation via `tools/cert-rotate.sh`.
5. Both PEM (for python/go clients) and PKCS12 (for JVM services) formats emitted per leaf.
6. Connect REST endpoint (`:8083`) becomes HTTPS with client-cert auth. PR 8 basic-auth JAAS removed.
7. Cert-expiry SLO with alerts at 14d/expired via existing blackbox exporter.

## 2. Non-Goals

- Auto-renewal sidecars (leaf rotation is manual per Q5 A decision).
- Vault / cert-manager / real CA — step-ca chosen for realism without extra infra.
- Rotating CA / Intermediate mid-PR — out of scope; documented as future work.
- mTLS on non-Kafka HTTP surfaces (Grafana, Prometheus UI, LocalStack, ntfy) — dev surfaces stay HTTP with `127.0.0.1` bind.
- Encryption of records at rest (that is PR 10 via Kroxylicious).

## 3. Architecture

### 3.1 New services (base profile)

| Service | Image | Purpose |
|---|---|---|
| `step-ca-init` | `smallstep/step-ca:0.26.x` (pin exact tag at implementation) | One-shot: init step-ca config, generate Root CA (10y), Intermediate CA (5y), write to volume `pki-root`. Idempotent (exits fast if `root.crt` already exists). |
| `cert-issuer` | custom small image built from `smallstep/step-cli` | Callable via `docker compose run --rm cert-issuer <svc-name>`. Uses Intermediate to mint leaf (90d) with SANs `<svc-name>` and `localhost` (for external CN). Writes PEM + PKCS12 under `pki-certs/pem/<svc>` and `pki-certs/jks/<svc>`. Also invoked automatically by `bootstrap-certs` on first `up`. |
| `bootstrap-certs` | reuses `cert-issuer` image | One-shot loop: iterates the service→CN table (embedded), issues any missing leaf. Depends on `step-ca-init` completed. |
| `acl-bootstrap` | `apache/kafka:3.8.x` (already in stack) | One-shot after brokers healthy: runs `kafka-acls` for every ACL in §5. Idempotent (uses `--add`, existing ACLs are no-ops). |

### 3.2 Removed / stripped

- Broker listeners `PLAINTEXT://:9092`, `SASL_PLAINTEXT://:9095`, `SASL_SSL://:9096`, `EXTERNAL://:29092` (all replaced — see §3.3).
- `KAFKA_ALLOW_PLAINTEXT_LISTENER=yes` on brokers.
- SCRAM-SHA-512 users and JAAS files.
- Connect basic-auth JAAS extension (`services/kafka-connect/entrypoint-secrets.sh` still generates the trust material but no longer basic-auth secrets; refactored to generate ssl.properties).
- `SASL_JAAS_CONFIG` env from every client service.

### 3.3 Broker + controller listener matrix (post-PR-9)

| Name | Protocol | Purpose | Client auth |
|---|---|---|---|
| `SSL` | SSL:9096 | in-cluster client mTLS | required |
| `SSL_INTER` | SSL:9094 | inter-broker replication | required |
| `SSL_EXTERNAL` | SSL:29092 (host-published as `127.0.0.1:9092`) | host tooling | required |
| controller (per-node) | SSL:9093 | controller quorum | required |

Broker env:
- `KAFKA_LISTENERS=SSL://:9096,SSL_INTER://:9094,SSL_EXTERNAL://:29092`
- `KAFKA_INTER_BROKER_LISTENER_NAME=SSL_INTER`
- `KAFKA_ADVERTISED_LISTENERS=SSL://broker{N}:9096,SSL_INTER://broker{N}:9094,SSL_EXTERNAL://127.0.0.1:{9092|9093|9094}`
- `KAFKA_SSL_KEYSTORE_LOCATION=/certs/jks/broker{N}/keystore.p12`
- `KAFKA_SSL_KEYSTORE_TYPE=PKCS12`, `KAFKA_SSL_KEYSTORE_PASSWORD=changeit-dev-only`
- `KAFKA_SSL_TRUSTSTORE_LOCATION=/certs/jks/broker{N}/truststore.p12`
- `KAFKA_SSL_TRUSTSTORE_TYPE=PKCS12`, `KAFKA_SSL_TRUSTSTORE_PASSWORD=changeit-dev-only`
- `KAFKA_SSL_CLIENT_AUTH=required`
- `KAFKA_SSL_PRINCIPAL_MAPPING_RULES=RULE:^CN=(.*?),.*$/$1/L,DEFAULT`
- `KAFKA_AUTHORIZER_CLASS_NAME=org.apache.kafka.metadata.authorizer.StandardAuthorizer`
- `KAFKA_ALLOW_EVERYONE_IF_NO_ACL_FOUND=false`
- `KAFKA_SUPER_USERS=User:admin;User:host-admin;User:broker1;User:broker2;User:broker3;User:controller1;User:controller2;User:controller3` (see §5.2 for rationale — Kafka super.users is exact-match, no wildcards)

Controller env (identical crypto material path pattern, own cert):
- `KAFKA_LISTENERS=CONTROLLER://:9093`, `KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER`
- `KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:SSL,SSL:SSL,SSL_INTER:SSL,SSL_EXTERNAL:SSL` (applies to controller-only and to broker+controller alike as needed)

### 3.4 Client-side changes

| Service | Change |
|---|---|
| `kafka-connect` | Producer/consumer `security.protocol=SSL` + JKS mounts. REST: `listeners=https://0.0.0.0:8083`, `listeners.https.ssl.client.auth=required`, own keystore, PR8 basic-auth env stripped. |
| `schema-registry` | `SCHEMA_REGISTRY_KAFKASTORE_SECURITY_PROTOCOL=SSL` + JKS. REST client-cert auth enabled (`SCHEMA_REGISTRY_SSL_CLIENT_AUTHENTICATION=REQUIRED`). |
| `akhq` | `application.yml` cluster block: `security.protocol: SSL`, `ssl.keystore.location`, `ssl.truststore.location`, both PKCS12, passwords via env. Schema-registry client also given cert. |
| `kminion` | `kafka.tls.enabled=true`, `kafka.tls.ca_filepath`, `kafka.tls.cert_filepath`, `kafka.tls.key_filepath` (PEM). SASL fully removed. |
| `cruise-control` | `security.protocol=SSL`, JKS keystore/truststore, `ssl.endpoint.identification.algorithm=` empty (matches SANs). |
| `loadgen` | `kafka-python` `security_protocol='SSL'`, `ssl_cafile`, `ssl_certfile`, `ssl_keyfile` from `/certs/pem/loadgen/`. |
| `mcp-kafka` | Same PEM triple. `KAFKA_SECURITY_PROTOCOL=SSL` env. |
| `prometheus` | New blackbox module `ssl_cert_expiry` targeting `broker1:9096`, `broker2:9096`, `broker3:9096`, `controller1:9093`, `controller2:9093`, `controller3:9093`, `kafka-connect:8083`. |
| `blackbox-exporter` | Config gets `ssl_cert_expiry` HTTP prober with `fail_if_not_ssl: true`, cert client optional. |
| `tools/kafka.sh` | Wraps `kafka-*` CLIs with `--command-config /certs/pem/host/client.properties`. Adds host-admin cert path. New env `KAFKA_BOOTSTRAP_LOCAL=localhost:9092` (external listener host mapping). |

### 3.5 Startup ordering (updates doc 02 §4)

1. `step-ca-init` (once). 2. `bootstrap-certs` (issues all leaves). 3. controllers → healthy (mTLS ready). 4. brokers → healthy. 5. `acl-bootstrap` → completed. 6. schema-registry + localstack. 7. kafka-connect (needs ACLs + connect topics can be created). 8. akhq, mcp-kafka, kminion, cruise-control. 9. loadgen. Observability plane parallel (uses TLS to scrape via blackbox where needed).

## 4. PKI Layout

Two named volumes:

- `pki-root`: rw only by `step-ca-init` and `cert-issuer`. Contains `/step/config/*`, `/step/secrets/root_ca_key`, `/step/secrets/intermediate_ca_key`, provisioner password file.
- `pki-certs`: rw by `cert-issuer` and `bootstrap-certs`; ro by every consuming service.

`pki-certs` directory tree:
```
/certs/
├── ca/
│   ├── root.crt
│   ├── intermediate.crt
│   └── ca-bundle.pem
├── pem/<svc>/
│   ├── tls.crt
│   ├── tls.key
│   └── ca-bundle.pem   (symlink to ../../ca/ca-bundle.pem)
├── jks/<svc>/
│   ├── keystore.p12    (leaf + private key, pw=changeit-dev-only)
│   └── truststore.p12  (ca-bundle, pw=changeit-dev-only)
└── host/
    ├── tls.crt, tls.key, ca-bundle.pem  (for host-admin principal)
    └── client.properties  (kafka CLI SSL config, prefilled)
```

## 5. Principal + ACL Model

### 5.1 Service → CN table

| Service | CN | Principal (post-rule) | Notes |
|---|---|---|---|
| broker1 / broker2 / broker3 | `broker1` etc | `User:broker1` | Also matches super-user `User:broker` (super list is Set membership OR exact — we add both `broker` and each `brokerN` to super to keep the model simple; see §5.2) |
| controller1 / controller2 / controller3 | `controller1` etc | `User:controller1` etc | super via `User:controller*` — see §5.2 |
| kafka-connect | `kafka-connect` | `User:kafka-connect` | |
| schema-registry | `schema-registry` | `User:schema-registry` | |
| akhq | `akhq` | `User:akhq` | |
| kminion | `kminion` | `User:kminion` | |
| cruise-control | `cruise-control` | `User:cruise-control` | |
| loadgen | `loadgen` | `User:loadgen` | |
| mcp-kafka | `mcp-kafka` | `User:mcp-kafka` | |
| admin | `admin` | `User:admin` | superuser used by acl-bootstrap and rescue |
| host-admin | `host-admin` | `User:host-admin` | superuser for host tooling (dev) |

### 5.2 Super users

Because `super.users` in Kafka takes an exact-match list (no wildcards), enumerate:
`User:admin;User:host-admin;User:broker1;User:broker2;User:broker3;User:controller1;User:controller2;User:controller3`.

### 5.3 ACL commands

`acl-bootstrap` runs (all with `--bootstrap-server broker1:9096 --command-config /certs/pem/admin/client.properties`, iterating idempotently):

```
# loadgen
kafka-acls --add --producer --topic events --allow-principal User:loadgen

# kafka-connect (S3 sink) — consumer group is 'connect-s3-sink'
kafka-acls --add --consumer --topic events --group connect-s3-sink --allow-principal User:kafka-connect
kafka-acls --add --allow-principal User:kafka-connect --operation All --topic __connect-configs
kafka-acls --add --allow-principal User:kafka-connect --operation All --topic __connect-offsets
kafka-acls --add --allow-principal User:kafka-connect --operation All --topic __connect-status
kafka-acls --add --allow-principal User:kafka-connect --operation DescribeConfigs --cluster
kafka-acls --add --allow-principal User:kafka-connect --operation Create --cluster

# schema-registry
kafka-acls --add --allow-principal User:schema-registry --operation All --topic _schemas
kafka-acls --add --allow-principal User:schema-registry --operation All --group schema-registry

# akhq (read-only observability)
kafka-acls --add --allow-principal User:akhq --operation Describe --cluster
kafka-acls --add --allow-principal User:akhq --operation Read --topic '*'
kafka-acls --add --allow-principal User:akhq --operation Describe --topic '*'
kafka-acls --add --allow-principal User:akhq --operation Read --group '*'
kafka-acls --add --allow-principal User:akhq --operation Describe --group '*'

# kminion
kafka-acls --add --allow-principal User:kminion --operation Describe --cluster
kafka-acls --add --allow-principal User:kminion --operation Describe --topic '*'
kafka-acls --add --allow-principal User:kminion --operation Describe --group '*'

# cruise-control
kafka-acls --add --allow-principal User:cruise-control --operation Describe --cluster
kafka-acls --add --allow-principal User:cruise-control --operation DescribeConfigs --cluster
kafka-acls --add --allow-principal User:cruise-control --operation Alter --cluster
kafka-acls --add --allow-principal User:cruise-control --operation AlterConfigs --cluster
kafka-acls --add --allow-principal User:cruise-control --operation Describe --topic '*'
kafka-acls --add --allow-principal User:cruise-control --operation Read --topic '*'

# mcp-kafka
kafka-acls --add --allow-principal User:mcp-kafka --operation Describe --cluster
kafka-acls --add --allow-principal User:mcp-kafka --operation Read --topic '*'
kafka-acls --add --allow-principal User:mcp-kafka --operation Describe --topic '*'
kafka-acls --add --allow-principal User:mcp-kafka --operation Read --group 'mcp-tail-*'
```

Default posture: `allow.everyone.if.no.acl.found=false`. Anything without an ACL and not a super-user is denied.

## 6. Observability

### 6.1 Cert expiry

Blackbox exporter module `ssl_cert_expiry`:
```yaml
modules:
  ssl_cert_expiry:
    prober: tcp
    timeout: 5s
    tcp:
      tls: true
      tls_config:
        insecure_skip_verify: true
```

Prometheus job:
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
        - schema-registry:8081
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: instance
    - target_label: __address__
      replacement: blackbox-exporter:9115
```

Recording rule:
```yaml
- record: slo:cert_days_until_expiry
  expr: (probe_ssl_earliest_cert_expiry - time()) / 86400
```

Alerts:
- `KafkaCertExpiringSoon` — `slo:cert_days_until_expiry < 14 for 30m` → warn.
- `KafkaCertExpired` — `slo:cert_days_until_expiry < 0 for 5m` → critical.

### 6.2 Auth failures

Existing broker logs (via loki/filelog) now carry `SSLHandshakeException` and `TOPIC_AUTHORIZATION_FAILED`. New Grafana panel in `kafka-security.json`:
- Log-rate panel: `sum by (container_name) (rate({container_name=~"broker.*"} |= "SSLHandshakeException" [5m]))`.
- Log-rate panel: `sum by (container_name) (rate({container_name=~"broker.*"} |= "TOPIC_AUTHORIZATION_FAILED" [5m]))`.
- Alert `KafkaAuthFailureBurst` — either rate > 1/s for 5m → warn.

## 7. Failure Map Additions (append to doc 03 §6)

| Failure | Immediate effect | Downstream propagation | Detection SLI |
|---|---|---|---|
| Any leaf cert expired | client’s SSL handshake fails; producer/consumer disconnected | that service’s data plane offline until rotate | `slo:cert_days_until_expiry < 0` |
| Intermediate CA cert expired | ALL clients fail handshake | full data plane outage | same rule, target = any endpoint |
| ACL mis-config (missing rule) | client authenticated, ops rejected `TOPIC_AUTHORIZATION_FAILED` | that operation blocked; no timeout | `KafkaAuthFailureBurst` alert |
| step-ca-init volume corrupt | `bootstrap-certs` cannot issue new certs; stack fails to start on fresh boot | full stack down at boot | acl-bootstrap fails; `docker compose ps` shows non-healthy brokers |

## 8. Testing

### 8.1 Syntax / config

- `bash -n` on `step-ca-init.sh`, `cert-issuer.sh`, `bootstrap-certs.sh`, `acl-bootstrap.sh`, `tools/kafka.sh`, `tools/mtls-verify.sh`, `tools/cert-rotate.sh`.
- `docker compose config` clean.
- `openssl verify -CAfile /certs/ca/ca-bundle.pem /certs/pem/<svc>/tls.crt` for every issued leaf (loop in `bootstrap-certs`).
- `promtool check config` + `promtool check rules` on updated Prometheus config.

### 8.2 Integration — `tools/mtls-verify.sh`

Fail-fast script; each assertion tagged. After `docker compose up -d` completes and stack is healthy:

1. PKI verify: `docker compose run --rm cert-issuer step certificate verify /certs/pem/loadgen/tls.crt --roots /certs/ca/root.crt` → exit 0.
2. Plaintext gone: `docker compose exec broker1 sh -c "ss -ltn '( sport = :9092 or sport = :9095 or sport = :9096 )'"` shows only `9096`. TCP probe from another container to `broker1:9092` → connection refused.
3. Unauth reject: from a temp `apache/kafka` container without any keystore, `kafka-topics --bootstrap-server broker1:9096 --list --command-config /empty.properties` fails with SSL error.
4. Wrong-cert reject: mint an off-CA cert manually (openssl one-liner), attempt bootstrap → broker log shows `SSLHandshakeException`.
5. ACL enforced: `loadgen` cert produces to `events` → OK; same cert tries `kafka-topics --describe _schemas` → `TOPIC_AUTHORIZATION_FAILED`.
6. Host wrapper: `tools/kafka.sh topic-list` (uses host-admin cert) → returns topic list including `events`, `_schemas`, `__connect-*`.
7. Connect REST: `curl --cacert /certs/host/ca-bundle.pem https://localhost:8083/connectors` → SSL handshake fails without cert. With `--cert /certs/host/tls.crt --key /certs/host/tls.key` → HTTP 200 JSON array.
8. AKHQ reachable via HTTP UI, cluster tab shows brokers online (proves akhq client-cert works).
9. Prometheus `up{}` for all Kafka-adjacent scrape jobs = 1. `probe_ssl_earliest_cert_expiry{}` present for all cert-expiry targets.

### 8.3 Chaos — extend `tools/chaos-run.sh`

| Scenario | Action | Expected alert | Max detection |
|---|---|---|---|
| `cert-expiry-warn` | issue a temp leaf for `loadgen` with `--not-after 60s`, restart loadgen, wait | `KafkaCertExpiringSoon` (rule threshold temporarily 60s for test) then `KafkaCertExpired` | 3m |
| `bad-cert-rejected` | mint cert off unknown CA, mount over loadgen’s, restart loadgen | broker log line `SSLHandshakeException` observed via loki query; assert loadgen `up`=0 and no produce metrics | 2m |

### 8.4 Rotation demo

`tools/cert-rotate.sh <svc>` script (not in CI): calls cert-issuer for that leaf then `docker compose restart <svc>`. Manual walkthrough in doc 04.

### 8.5 PR 10 pre-flight

After PR 9 merged, PR 10 branch (already exists as `pr10-kroxylicious-kms`) rebases onto main and updates its spec/plan: kroxylicious upstream config gets SSL + trust bundle; `loadgen-proxy` uses `KAFKA_BOOTSTRAP=kroxylicious:9192` still plaintext to *proxy* (proxy-facing listener stays plaintext in-network only; document trade-off). Alternatively, PR 10 upgrades proxy listener to SSL too — that is a PR 10 decision, not PR 9.

## 9. File & Directory Changes

- `clusters/docker-compose.yml` — listeners, envs, new services, volume mounts.
- `clusters/step-ca/init/step-ca-init.sh` (new)
- `clusters/step-ca/init/bootstrap-certs.sh` (new)
- `clusters/step-ca/init/services.csv` (new) — service→CN list consumed by bootstrap script
- `clusters/step-ca/Dockerfile` (new, minimal — smallstep base + awk/openssl for PKCS12 wrap)
- `clusters/kafka/acl-bootstrap.sh` (new)
- `services/kafka-connect/entrypoint-secrets.sh` — remove basic-auth generation, add ssl.properties emission
- `services/loadgen/app/loadgen.py` — SSL producer args
- `services/mcp-kafka/app/server.py` — SSL client args
- `services/kminion/kminion.yaml` — tls block replacing sasl
- `services/akhq/application.yml` — cluster ssl block
- `services/cruise-control/config/cruisecontrol.properties` — SSL props
- `services/schema-registry/*` — env-driven SSL
- `prometheus/prometheus.yml` — cert_expiry job
- `prometheus/rules/mtls.rules.yml` — recording rule + alerts
- `blackbox/blackbox.yml` — new module
- `grafana/dashboards/kafka-security.json` — 2 log panels + expiry stat
- `tools/kafka.sh` — SSL wrapper
- `tools/mtls-verify.sh` (new)
- `tools/cert-rotate.sh` (new)
- `tools/chaos-run.sh` — 2 new scenarios
- Docs: `04-SECURITY-GUARDRAILS.md` §2 rewrite listener matrix; `02-INTEGRATION-ARCHITECTURE.md` §4 startup ordering; `03-DATA-FLOW-ARCHITECTURE.md` §6 failure rows.
- Delete: any `*.jaas`, `*_scram_*.sh`, `services/kafka-connect/rest-auth.jaas` (PR8 artefact).

## 10. Trade-offs & Risks

- **Boot cost**: first `up` runs step-ca-init + bootstrap-certs (~15–30s extra) — one-time per volume lifetime.
- **Password reuse (`changeit-dev-only`) across all keystores**: dev-only convenience. Documented; prod would inject per-service Docker secrets.
- **`super.users` list must enumerate each broker/controller CN** — six lines; a new broker requires adding its CN. Not automated; documented.
- **Host wrapper `kafka.sh` bakes host-admin superuser**: dev-only convenience; documented as "do not carry into prod".
- **PR 8 basic-auth completely removed**: any external doc/tool referencing basic-auth on Connect REST must be updated (grep gate in the plan).
- **cruise-control mTLS with 3-broker cluster**: cruise-control expects broker JMX metrics; JMX is not TLS-wrapped here. Kept plaintext JMX inside the compose network only (documented). Alternative (JMX TLS) is out of scope.
- **Manual leaf rotation**: leaves expire in 90d. `KafkaCertExpiringSoon` at 14d gives runway. Missing the alert = outage. Documented.

## 11. Open Questions (resolve during implementation, not blocking)

- Exact `smallstep/step-ca` and `apache/kafka` tag pins.
- Whether cruise-control build needs a rebuild to accept PKCS12 (some versions want JKS only). Fallback: emit JKS as well.
- Whether schema-registry client mTLS breaks AKHQ's built-in Avro rendering — validate in `mtls-verify.sh` step 8.
- Whether Prometheus's Kafka Connect scrape (if any) needs TLS client cert — check existing job definition at implementation.
