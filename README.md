# Kafka KRaft Lab — Platform-Engineering Showcase

Production-shaped Kafka lab: 3-controller / 3-broker KRaft cluster with Kafka
Connect S3 sink, LGTM(P) observability, Cruise Control rebalancing, an
AI-facing MCP control plane, and end-to-end mTLS between every service.
Runs on rootless Podman **or** Docker Engine from a single `docker compose`
file — no cloud, no ZooKeeper.

Design lives under `00-INDEX.md` → `05-OBSERVABILITY-SLO-SLI.md`.
See `wiki/Home.md` for the operator quickstart.

> Origem PT-BR: as issues antigas e alguns diagramas ainda estão em
> português. Toda documentação nova segue em inglês para alinhar com o
> restante da esteira de plataforma.

## Stack (25 services)

| Plane | Services |
|---|---|
| Kafka data | `controller1-3`, `broker1-3` (KRaft, no ZK) |
| Integration | `kafka-connect` (S3 sink), `schema-registry`, `kroxylicious` (record-encryption profile) |
| Admin UIs | `akhq`, `kminion`, `cruise-control` |
| Storage emulation | `localstack` (S3, KMS) |
| Observability | `prometheus`, `grafana`, `loki`, `tempo`, `pyroscope`, `alertmanager`, `blackbox-exporter`, `otel-collector` |
| Notifications | `ntfy` |
| Chaos / load | `toxiproxy`, `loadgen` |
| AI control plane | `mcp-kafka` (Tier-0 read-only MCP server over SSE + Bearer auth) |
| PKI | `step-ca` (offline, one-shot cert issuance) |

Central version pinning: `clusters/.env`. Per-service Dockerfiles + configs
under `services/<name>/`.

## Prerequisites

Validated on rootless Podman 4.9 (Ubuntu 24.04). Docker Engine works with no
extra setup. Podman requires:

1. **netavark + aardvark-dns** — container-to-container DNS.
   ```bash
   sudo apt install -y netavark aardvark-dns
   mkdir -p ~/.config/containers
   printf '[network]\nnetwork_backend = "netavark"\n' > ~/.config/containers/containers.conf
   echo netavark > ~/.local/share/containers/storage/defaultNetworkBackend
   rm -f ~/.local/share/containers/storage/networks/*.json \
         ~/.local/share/containers/storage/networks/netavark.lock
   systemctl --user restart podman.socket podman.service
   podman info --format '{{.Host.NetworkBackend}}'   # → netavark
   ```
2. **After `podman system reset`** — `systemctl --user restart
   podman.socket podman.service`, otherwise the socket returns
   `attempt to write a readonly database`.
3. **Explicit `ipam.config`** — set in `clusters/docker-compose.yml`
   (compose v5.3.1 crashes with `ParseAddr("<nil>")` on internal bridges
   when the gateway is left implicit).

## Quick start

```bash
./kafka.sh start              # brings up all 25 services
./kafka.sh doctor             # runtime health probe
./kafka.sh ui                 # print all host-exposed URLs
./kafka.sh connector-create   # register S3 sink on kafka-connect
./kafka.sh run-loadgen        # start continuous traffic
./kafka.sh stop               # tear down
```

Full helper reference: `./kafka.sh help`.

### Host-exposed UIs (`127.0.0.1` only)

| URL | Service |
|---|---|
| http://localhost:8080 | AKHQ |
| https://localhost:8081 | Schema Registry (mTLS) |
| https://localhost:8083 | Kafka Connect REST (mTLS + basic auth) |
| https://localhost:9095 | Cruise Control REST (mTLS + basic auth) |
| https://localhost:3001 | mcp-kafka (SSE + Bearer) |
| http://localhost:8082 | ntfy |
| http://localhost:4566 | LocalStack (AWS API) |
| http://localhost:9090 | Prometheus |
| http://localhost:3000 | Grafana (admin/`GRAFANA_ADMIN_PASSWORD`) |
| http://localhost:8474 | Toxiproxy API |
| `localhost:9192` | Kroxylicious proxy (Kafka protocol) |
| `localhost:9092/9093/9094` | Broker bootstrap |

Cluster-internal only: Loki :3100, Tempo :3200, Pyroscope :4040,
Alertmanager :9093, Blackbox :9115, JMX exporter :7071 on every JVM.

## Architecture docs

| Doc | Focus |
|---|---|
| [`00-INDEX.md`](00-INDEX.md) | Doc map + PR roadmap status |
| [`01-NETWORK-ARCHITECTURE.md`](01-NETWORK-ARCHITECTURE.md) | 4-zone segmentation (`kafka-quorum` / `kafka-data` / `observability` / `edge`), listener + port map |
| [`02-INTEGRATION-ARCHITECTURE.md`](02-INTEGRATION-ARCHITECTURE.md) | Component contracts, startup ordering, MCP control-plane design |
| [`03-DATA-FLOW-ARCHITECTURE.md`](03-DATA-FLOW-ARCHITECTURE.md) | Produce → S3 semantics, KRaft metadata, failure-propagation map |
| [`04-SECURITY-GUARDRAILS.md`](04-SECURITY-GUARDRAILS.md) | Findings F1–F14, 6-phase remediation, MCP guardrails |
| [`05-OBSERVABILITY-SLO-SLI.md`](05-OBSERVABILITY-SLO-SLI.md) | Metric inventory, 13 SLOs + error budgets, PromQL alert rules |
| [`PLAN-DOCKERFILES.md`](PLAN-DOCKERFILES.md) | Per-service Dockerfiles migration record (all 7 phases complete) |
| [`tools/README-chaos.md`](tools/README-chaos.md) | `chaos.sh` + `chaos-run.sh` fault-injection harness |
| [`wiki/Home.md`](wiki/Home.md) | Operator-oriented quickstart |

## Chaos harness

Toxiproxy-driven; asserts the failure-propagation map from
`03-DATA-FLOW-ARCHITECTURE.md`.

```bash
./tools/chaos.sh list                    # available scenarios
./tools/chaos-run.sh <scenario>          # run + record detection time
```

## MCP control plane

`services/mcp-kafka/` exposes a Tier-0 (read-only) FastMCP server over SSE
with Bearer-token auth (env `MCP_AUTH_TOKEN`). Tools include
`search_logs`, `get_trace`, `get_profile`, `cluster_balance_status`,
`get_consumer_lag`, `tail_topic`, and `chaos_status`. Full contract:
[`02-INTEGRATION-ARCHITECTURE.md`](02-INTEGRATION-ARCHITECTURE.md#3-mcp-integration-layer-the-with-mcp-part).

Tier-1 mutations are gated behind `MCP_MODE=admin` and are off by default.

## Security posture

- **mTLS end-to-end**: every service holds a leaf cert issued by the
  in-repo Smallstep CA (`clusters/step-ca/`). Brokers accept only SSL
  clients; Kafka Connect, Schema Registry, and Cruise Control REST all
  serve HTTPS; MCP-Kafka reads observability backends over HTTPS.
- **ACLs**: per-principal, no wildcards; enforced on the SSL listener.
- **Secrets**: `.env` holds placeholders; production uses env-file
  injection or K8s Secret projected volumes (`KAFKA_SASL_PASSWORD_FILE`
  pattern in mcp-kafka).
- **Supply chain**: pinned tags, `.trivyignore` per service, Trivy +
  gitleaks gates in CI.

## S3 sink quick verify

```bash
# produce a burst
./kafka.sh run-producer
# check what landed in the LocalStack bucket
podman exec localstack awslocal s3 ls s3://kafka-events-bucket --recursive
```

The connector flushes on **3 messages** OR **60s**, whichever comes first.
Empty bucket = neither threshold hit yet.

## Troubleshooting

| Symptom | Check |
|---|---|
| Container-to-container DNS fails on Podman | `podman info` → NetworkBackend must be `netavark`; `dpkg -l aardvark-dns` |
| `attempt to write a readonly database` | `systemctl --user restart podman.socket podman.service` |
| Brokers accept TCP but Connect fails to bootstrap | Waiting on healthchecks — see `02-INTEGRATION-ARCHITECTURE.md §4` |
| No files in S3 | Flush threshold not met — send 3 messages or wait 60s |
| Prometheus targets down | `http://localhost:9090/targets`; JMX exporter on `:7071` inside each JVM container |
| MCP SSE returns 401 | `Authorization: Bearer $MCP_AUTH_TOKEN` header required |

## Repository layout

```
kafka_project/
├── clusters/                  # docker-compose.yml + .env (single source of truth)
├── services/<name>/           # per-service Dockerfile + config + agents
├── connects/                  # S3 sink connector JSON + helper
├── producers/                 # sample Python producers
├── tools/                     # chaos harness + operator helpers
├── scripts/                   # bootstrap + verification scripts
├── diagrams/                  # source (.drawio) + rendered .svg
├── docs/                      # ADRs + deep-dive notes
├── wiki/                      # operator-facing quickstart
├── data/                      # sample data for producers
├── 00-05-*.md                 # architecture doc series
├── PLAN-DOCKERFILES.md        # migration record
└── kafka.sh                   # helper — run from anywhere in the repo
```

## References

- [Kafka KRaft](https://kafka.apache.org/documentation/#kraft)
- [Confluent S3 Sink Connector](https://docs.confluent.io/kafka-connectors/s3-sink/current/overview.html)
- [LocalStack](https://docs.localstack.cloud/)
- [FastMCP](https://github.com/jlowin/fastmcp)
- [Cruise Control](https://github.com/linkedin/cruise-control)
- [Kroxylicious](https://kroxylicious.io/)
- [Grafana LGTM stack](https://grafana.com/oss/)
