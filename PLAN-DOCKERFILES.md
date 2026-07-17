# Plan — Per-Service Dockerfiles Migration

Goal: replace every `image:` in `clusters/docker-compose.yml` with `build: services/<name>/` so each service is reproducibly built with baked configs, agents, and plugins. Prepares for adding `mcp-kafka`, `cruise-control`, `kroxylicious`, `toxiproxy`, `loadgen` and for wiring OTel javaagents into JVM services.

Chosen conventions (from `AskUserQuestion` this session):
- **Layout**: `services/<name>/` with `Dockerfile` + `config/` + `agents/` as needed.
- **Version pinning**: `ARG BASE_IMAGE=...` + `ARG BASE_TAG=...` at top of every Dockerfile; overridable via compose `build.args` and central `clusters/.env`.
- **Config migration**: `git mv` from `clusters/config/*` and `metrics/*` into `services/<svc>/config/`. No duplicates.
- **JAR fetch**: build-time `ADD https://...` with pinned URL + SHA256 checked via `RUN sha256sum -c`. No JAR blobs in git.

## Scope

25 services in 4 categories:

| Category | Count | Services |
|---|---|---|
| Kafka JVM (cp-kafka 7.7.1) | 6 | controller1–3, broker1–3 |
| Confluent JVM (Connect / Schema Registry) | 2 | kafka-connect, schema-registry |
| Observability upstream (thin config wrap) | 11 | prometheus, grafana, loki, tempo, pyroscope, alertmanager, blackbox-exporter, otel-collector, kminion, ntfy, localstack |
| App / admin | 1 | akhq |
| **New** (not currently in stack) | 5 | mcp-kafka, cruise-control, kroxylicious, toxiproxy, loadgen |

controller/broker share one `services/broker/` image with different `command:` if practical, else split into `services/controller/` + `services/broker/`. Decision at phase 2 start.

## Phase plan

### Phase 0 — plan doc + branch
- [x] Write this plan (`PLAN-DOCKERFILES.md`)
- [x] Branch: `feat/per-service-dockerfiles`
- [x] User review + go-ahead

## Outcome (all phases complete)

- 25 of 25 services boot green from `./kafka.sh start` (or `docker compose up -d`).
- Every service builds from `services/<name>/Dockerfile`; no `image:` remains
  in `clusters/docker-compose.yml` outside comments.
- Central version pins in `clusters/.env`.
- JMX exporter, OpenTelemetry javaagent, and Cruise Control metrics reporter
  are baked into the broker image (reporter built from source in an isolated
  gradle stage — not on Maven Central). Controllers, kafka-connect, and
  schema-registry bake JMX + OTel javaagent.
- OTel javaagent activation env (`OTEL_SERVICE_NAME`, OTLP endpoint, exporter
  wiring) added to every JVM service in compose.
- New services delivered: mcp-kafka (Tier-0 FastMCP), loadgen, cruise-control,
  kroxylicious (pass-through, filter chain TBD), toxiproxy.
- Kroxylicious 0.10.0 required the map-form `virtualClusters:` schema and
  `filterDefinitions: []`; noted here so future config work uses 0.10 grammar.
- Cruise Control requires `kafka.broker.failure.detection.enable=true` under
  KRaft (no ZK), plus explicit `hard.goals` matching `default.goals`.
- Loadgen uses `restart: on-failure` to survive the broker warm-up race.

### Phase 1 — skeleton + config migration
- [ ] Create `services/<name>/` for all 25 (empty dirs first)
- [ ] `git mv clusters/config/*.yaml services/<owner>/config/`
- [ ] `git mv metrics/jmx-exporter/` → `services/broker/config/jmx/` (shared source; each JVM Dockerfile copies from build context)
- [ ] `git mv metrics/grafana/{dashboards,datasources}` → `services/grafana/provisioning/`
- [ ] `git mv metrics/prometheus/` → `services/prometheus/config/`
- [ ] Update compose bind mounts to point at new paths. Boot stack. Verify green.
- [ ] Commit: `refactor: relocate service configs under services/ tree`

### Phase 2 — Java stack Dockerfiles (8 images)
Order: broker → controller → kafka-connect → schema-registry.

Each `services/broker/Dockerfile`:
```dockerfile
ARG BASE_IMAGE=confluentinc/cp-kafka
ARG BASE_TAG=7.7.1
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG JMX_EXPORTER_VERSION=1.0.1
ARG OTEL_AGENT_VERSION=2.10.0
ARG CC_METRICS_REPORTER_VERSION=2.5.138

USER root
RUN mkdir -p /opt/agents /opt/jmx_exporter
ADD --chmod=644 --checksum=sha256:<TBD> \
    https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
    /opt/jmx_exporter/jmx_prometheus_javaagent.jar
ADD --chmod=644 --checksum=sha256:<TBD> \
    https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar \
    /opt/agents/opentelemetry-javaagent.jar
ADD --chmod=644 --checksum=sha256:<TBD> \
    https://repo1.maven.org/maven2/com/linkedin/cruisecontrol/cruise-control-metrics-reporter/${CC_METRICS_REPORTER_VERSION}/cruise-control-metrics-reporter-${CC_METRICS_REPORTER_VERSION}.jar \
    /opt/agents/cruise-control-metrics-reporter.jar

COPY config/jmx/kafka-config.yml /opt/jmx_exporter/kafka-config.yml
USER appuser
```

Compose changes for each JVM service:
```yaml
  broker1:
    build:
      context: ../services/broker
      args:
        BASE_TAG: "7.7.1"
    environment:
      KAFKA_OPTS: >
        -javaagent:/opt/jmx_exporter/jmx_prometheus_javaagent.jar=7071:/opt/jmx_exporter/kafka-config.yml
        -javaagent:/opt/agents/opentelemetry-javaagent.jar
      # OTEL_* env for endpoint
      # cruise-control metrics reporter enabled via KAFKA_METRIC_REPORTERS
```

Verify: metrics still scraped, traces from brokers appear in Tempo under `service.name=broker1`, cruise-control topic `__CruiseControlMetrics` gets writes.

### Phase 3 — observability thin wraps (11 images)
Pattern (grafana example):
```dockerfile
ARG BASE_IMAGE=grafana/grafana
ARG BASE_TAG=11.2.0
FROM ${BASE_IMAGE}:${BASE_TAG}
COPY provisioning/ /etc/grafana/provisioning/
```
Pin `:latest` tags to explicit versions during this pass (observability stack currently uses `:latest` — reproducibility risk).

Version pins to set:
- grafana → 11.2.0
- prometheus → v2.55.0
- loki → 3.2.0
- tempo → 2.6.0 (already pinned in compose)
- pyroscope → 1.7.1
- alertmanager → v0.27.0
- blackbox-exporter → v0.25.0
- otel-collector → 0.156.0 (freeze current)
- kminion → v2.2.11
- ntfy → v2.11.0
- localstack → 3.8 (already pinned)

Verify: no dashboard/datasource regression, provisioner reload succeeds.

### Phase 4 — AKHQ
Dockerfile bakes `application.yml` (currently at `clusters/config/akhq.yml`) into `/app/application.yml`. Drops bind mount. Same UI, no config drift.

### Phase 5 — new Python/Go services
- **mcp-kafka** (Python 3.13 + FastMCP): starter Tier-0 tools (`list_topics`, `describe_topic`, `cluster_health`, `query_metrics`). Multi-stage build (deps → slim runtime).
- **loadgen** (Python + kafka-python-ng + OTel): steady N msg/s producer. Reuses instrumentation pattern from `producers/producer_example.py`.

### Phase 6 — new JVM/proxy services
- **cruise-control** (linkedin/cruise-control 2.5.138): download binary tarball, extract, config from `services/cruise-control/config/cruisecontrol.properties`. Depends on brokers having CC metrics reporter (phase 2).
- **kroxylicious** (`quay.io/kroxylicious/kroxylicious:0.10.0`): thin wrap, config with `RecordEncryption` filter pointing at LocalStack KMS.
- **toxiproxy** (`ghcr.io/shopify/toxiproxy:2.9.0`): API + wrap around Connect→LocalStack path. `toxics.json` provisioned via CLI init script.

### Phase 7 — compose rewrite + .env
- Replace every `image:` with `build: { context: ../services/<name>, args: {...} }`.
- Introduce `clusters/.env` for centralized version pinning; compose `${VAR:-default}` interpolation on `BASE_TAG` args.
- Delete now-unused `clusters/config/` (should be empty after phase 1).
- Delete now-unused bind mounts.
- Full `./kafka.sh stop && start` cycle.
- Commit: `refactor: build all services from services/<name>/Dockerfile`.

## Rollback

Each phase is a separate commit. Rollback = `git revert <phase-commit>` + `docker compose up -d --build`. No destructive volume ops needed at any phase.

## Risks

1. **Confluent images run as `appuser` uid 1000** — bind mounts (currently) work because host uid is 1001. After baking configs into image, permissions become container-internal. Should not break.
2. **JAR SHA256 pinning** — first pass needs SHA256 lookups; can `docker build` once locally, `docker exec` `sha256sum`, then hard-code.
3. **Cruise Control metrics reporter conflict** — adding a metric reporter to `KAFKA_METRIC_REPORTERS` might conflict with existing JMX. Reporter writes to `__CruiseControlMetrics` topic; JMX still exports MBeans. Should coexist.
4. **`:latest` → pinned** in phase 3 may change observed behavior (Grafana UI, Loki storage format). Test each individually.
5. **Compose `build:` context size** — with jars vendored via ADD, build context stays small.

## Deferred

- BuildKit cache mount for repeated builds (later, when build times hurt).
- Multi-arch (linux/arm64) — only linux/amd64 for now.
- Signed images (cosign) — production concern, not lab.
- Docker Hub push — local build only.

## Success criteria

- `docker compose build` builds all 25 images from source.
- `./kafka.sh start` boots stack; every dashboard populates as before (metrics/logs/traces).
- `git grep "image:" clusters/docker-compose.yml` returns 0 hits.
- All 5 new services (mcp-kafka, cruise-control, kroxylicious, toxiproxy, loadgen) reach Ready.
- README updated to reflect build-from-source workflow.
