# Chaos validation harness

Injects faults between `kafka-connect` and `localstack` (S3) via
[Toxiproxy](https://github.com/Shopify/toxiproxy) and asserts that the expected
Prometheus alert reaches Alertmanager within the SLO budget — i.e. the failure
map in [`03-DATA-FLOW-ARCHITECTURE.md §6`](../03-DATA-FLOW-ARCHITECTURE.md#6-backpressure--failure-propagation-map) is actually observable.

## Prerequisites

- Stack running (`docker compose up -d` in `clusters/`).
- S3 sink connector deployed and pointing at Toxiproxy: `connects/s3-sink-connector.json` uses `"store.url": "http://toxiproxy:4566"`. Reload via `connects/s3-connector.sh` if the connector was created before this repoint.
- `loadgen` producing to `events` (default in compose).
- Host tools: `bash`, `curl`, `jq`, `yq` (v4+). `docker` if you use the default Alertmanager-via-exec route.

## Scenarios

Defined declaratively in [`chaos-scenarios.yaml`](./chaos-scenarios.yaml). Each row: `name`, `toxic` (Toxiproxy `type`/`stream`/`attributes`), `expect_alert`, `max_detect_seconds`.

Current MVP set:

| Scenario | Toxic | Expected alert | Budget |
|---|---|---|---|
| `s3-latency-800ms` | 800 ms upstream latency | `ConnectTaskFailed` | 5 min |
| `s3-timeout` | 1 ms upstream connect timeout | `ConnectTaskFailed` | 5 min |
| `s3-bandwidth-64kb` | 64 KB/s upstream cap | `TopicBacklogHigh` | 8 min |

## `tools/chaos.sh` — ad-hoc control

```bash
tools/chaos.sh status                       # show proxy + active toxics
tools/chaos.sh apply s3-latency-800ms       # apply a named scenario (needs yq)
tools/chaos.sh apply-raw slow latency upstream '{"latency":800,"jitter":100}'
tools/chaos.sh clear                        # remove all toxics
```

Talks to `TOXIPROXY_API` (default `http://127.0.0.1:8474`, host-published on loopback).

## `tools/chaos-run.sh` — automated test harness

```bash
tools/chaos-run.sh                              # run all scenarios
tools/chaos-run.sh s3-latency-800ms s3-timeout  # run a subset
```

Per scenario: `clear` → `apply` → poll Alertmanager `/api/v2/alerts` every `POLL_INTERVAL_SECONDS` (default 10 s) until the expected alert becomes `active` — asserts elapsed ≤ `max_detect_seconds` — `clear` → wait for the alert to resolve.

Non-zero exit = at least one scenario missed its budget.

### Alertmanager access

Alertmanager isn't host-published. By default the harness runs `docker exec prometheus wget …` since both containers share the `observability` network. Override:

```bash
ALERTMANAGER_API=http://127.0.0.1:9093 tools/chaos-run.sh
ALERTMANAGER_EXEC_CONTAINER=grafana    tools/chaos-run.sh   # if prometheus is down
```

## Safety notes

- Every toxic is applied and removed by name — the harness always `clear`s before applying, so a previous crash doesn't compound.
- Scenarios run sequentially; do not compose. A `chaos.sh clear && chaos.sh status` between manual experiments is cheap.
- The 8 min budget for `s3-bandwidth-64kb` covers the `TopicBacklogHigh` `for:` duration (5 min) plus loadgen backpressure ramp — tune if you change `LOADGEN_RATE`.
