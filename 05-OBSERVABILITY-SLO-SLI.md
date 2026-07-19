# 05 — Metrics Tracking, SLIs & SLOs

> Complete metric inventory per system, the SLIs derived from them, SLO targets with error budgets, and the PromQL + alert rules that make each SLO enforceable.

## 1. Method

For each system: **golden signals** (latency, traffic, errors, saturation) → **SLI** (a ratio or quantile, always measurable in Prometheus) → **SLO** (target over a window) → **alert** (burn-rate style where applicable). A metric without an SLI attached is inventory; an SLI without an alert is decoration.

Windows: lab uses 7d rolling (30d in prod). Error budget = `1 − SLO`.

## 2. Kafka Brokers

### Metric inventory (JMX exporter :7071)
| Signal | Metric | Notes |
|---|---|---|
| Traffic | `kafka_server_brokertopicmetrics_messagesinpersec`, `bytesin/outpersec` | per-broker & per-topic |
| Latency | `kafka_network_requestmetrics_totaltimems{request="Produce"\|"Fetch",quantile}` | p99 is the SLI |
| Errors | `kafka_server_brokertopicmetrics_failedproducerequestspersec`, `failedfetchrequestspersec` | |
| Saturation | `kafka_server_replicamanager_underreplicatedpartitions`, `offlinereplicacount`; request handler idle % (`kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent`); `jvm_memory_heap_used/max` | |
| Integrity | `kafka_controller_kafkacontroller_activecontrollercount` (sum must = 1), `offlinepartitionscount` | |

### SLIs & SLOs
| SLI | Definition (PromQL) | SLO |
|---|---|---|
| Availability (write path) | `1 - (sum(rate(failedproducerequestspersec[5m])) / sum(rate(totalproducerequestspersec[5m])))` | ≥ 99.9% / 7d |
| Produce latency | `p99 totaltimems{request="Produce"}` | ≤ 50 ms (lab) |
| Fetch latency | `p99 totaltimems{request="Fetch"}` | ≤ 100 ms |
| Replication health | minutes with `underreplicatedpartitions > 0` | ≤ 0.1% of window |
| Partition availability | `offlinepartitionscount == 0` | 100% (any offline partition = incident) |

### Alerts (rules/kafka.yml)
```yaml
- alert: KafkaOfflinePartitions
  expr: sum(kafka_controller_kafkacontroller_offlinepartitionscount) > 0
  for: 1m
  labels: {severity: critical}
- alert: KafkaUnderReplicated
  expr: sum(kafka_server_replicamanager_underreplicatedpartitions) > 0
  for: 5m
  labels: {severity: warning}
- alert: KafkaProduceP99High
  expr: kafka_network_requestmetrics_totaltimems{request="Produce",quantile="0.99"} > 50
  for: 10m
  labels: {severity: warning}
- alert: KafkaNoActiveController
  expr: sum(kafka_controller_kafkacontroller_activecontrollercount) != 1
  for: 1m
  labels: {severity: critical}
```

## 3. KRaft Controllers

| Signal | Metric | SLI/SLO |
|---|---|---|
| Quorum health | `activecontrollercount` (cluster sum = 1) | 100%; ≠1 for >1m = critical |
| Raft lag | `kafka_server_raftmetrics_*` (commit latency, fetch lag) | commit p99 ≤ 20 ms |
| Metadata errors | `kafka_controller_kafkacontroller_metadataerrorcount`, `kafka_controller_controllereventmanager_eventqueuetimems_total` | error count = 0; event queue time p99 ≤ 100 ms |
| Broker fencing | `kafka_controller_kafkacontroller_activebrokercount`, `kafka_controller_kafkacontroller_fencedbrokercount` | fenced = 0 sustained |
| Saturation | JVM heap % per controller | ≤ 80% |

**SLO:** metadata-plane availability (topic create/describe succeeds) ≥ 99.9% / 7d — probed by a blackbox cron (`kafka-topics --describe` every 60s writing a success metric via pushgateway or textfile collector).

## 4. Kafka Connect + S3 Sink

### Metric inventory
| Signal | Metric |
|---|---|
| Task state | `kafka_connect_connector_task_status{state}` (1 running / 0 not) |
| Throughput | `kafka_connect_sink_task_sink_record_read_rate`, `put_batch_avg_time_ms` |
| Errors | `kafka_connect_task_error_metrics_total_record_failures`, `deadletterqueue_records` (if DLQ enabled) |
| Lag (the real SLI) | **kminion**: `kminion_kafka_consumer_group_topic_lag{group="connect-s3-sink"}` (offsets) + derived lag-in-seconds via recording rule `lag / rate(end_offset[5m])` |
| Saturation | Connect JVM heap % (the production OOM/premature-flush signal), rebalance rate `kafka_connect_connect_worker_rebalance_*` |

### SLIs & SLOs
| SLI | Definition | SLO |
|---|---|---|
| Sink freshness | `max(consumer_lag_seconds{group="connect-s3-sink"})` (lag ÷ produce rate, or kminion lag-in-time) | p99 ≤ 120 s / 7d |
| Task availability | % of time all tasks `RUNNING` | ≥ 99.5% |
| Delivery completeness | records read − records sent to DLQ / records read | ≥ 99.99% |
| Object quality | p50 S3 object size (fragmentation detector) | ≥ 0.5 × flush.size target |

### Alerts
```yaml
- alert: ConnectTaskNotRunning
  expr: sum(kafka_connect_connector_task_status{state="running"}) < sum(kafka_connect_connector_task_status)
  for: 3m
  labels: {severity: critical}
- alert: S3SinkLagBudgetBurn
  expr: max(kafka_consumergroup_lag_seconds{group="connect-s3-sink"}) > 120
  for: 5m
  labels: {severity: warning}
- alert: ConnectHeapPressure
  expr: jvm_memory_heap_used{job="kafka-connect"} / jvm_memory_heap_max > 0.85
  for: 10m
  labels: {severity: warning}   # early warning for the premature-flush failure mode
```

## 5. Schema Registry
| SLI | Metric/probe | SLO |
|---|---|---|
| API availability | blackbox `GET /subjects` success ratio | ≥ 99.9% |
| Lookup latency | jetty request p99 (`kafka_schema_registry_*` via JMX agent) | ≤ 50 ms |
| Compatibility violations | registration 409 rate | tracked, no SLO (it's the guardrail working) |

## 6. LocalStack S3 (sink dependency)
| SLI | Metric/probe | SLO |
|---|---|---|
| S3 availability | blackbox `GET /_localstack/health` + synthetic PutObject/GetObject canary every 60s | ≥ 99.5% |
| Put latency | canary duration histogram | p99 ≤ 500 ms |

**Dependency math:** sink freshness SLO (99.5%) cannot exceed S3 availability (99.5%) × Connect availability (99.5%) ⇒ composite ≈ 99.0% honest ceiling. Documenting this composition is exactly what SLO reviews look for.

**Recovery budget SLO:** `retention.ms` on `events` ≥ 24h ⇒ any sink outage < 24h is recoverable with zero loss. Alert when `lag_seconds > 0.5 × retention` (budget half-burned).

## 6.1 kminion (lag exporter — an SLI *source*, so it gets its own SLOs)
| SLI | Metric | SLO |
|---|---|---|
| Exporter availability | `up{job="kminion"}` | ≥ 99.5% |
| Data freshness | `absent(kminion_kafka_consumer_group_topic_lag)` must be false | no gaps > 5m |
| Scrape success | `kminion_exporter_offset_consumer_records_consumed_total` progressing | monotonic |

```yaml
- alert: LagMetricsStale
  expr: absent(kminion_kafka_consumer_group_topic_lag{group="connect-s3-sink"})
  for: 5m
  labels: {severity: critical}   # blind lag = blind freshness SLO — page on it
```

## 6.2 Cruise Control
| SLI | Metric (CC exposes JMX → :7071 agent, or /metrics) | SLO |
|---|---|---|
| Availability | blackbox `GET /kafkacruisecontrol/state` | ≥ 99% |
| Load model readiness | `monitored-partitions-percentage` ≥ 95% | within 15m of start |
| Anomaly detection | `anomaly-detector` broker-failure/disk-skew counters | alert on any anomaly, no SLO |
| Balance quality | disk/network utilization stddev across brokers | ≤ 20% skew (ticket, not page) |
| Rebalance safety | ongoing reassignment count + throttle adherence | reassignment window ≤ 30m |

## 7. Observability Stack (who watches the watcher)

### Prometheus + Grafana
| SLI | Metric | SLO |
|---|---|---|
| Scrape completeness | `avg_over_time(up[7d])` per target | ≥ 99.5% |
| Scrape latency | `scrape_duration_seconds` p99 | ≤ 5 s |
| TSDB health | `prometheus_tsdb_wal_corruptions_total` | 0 (production scar: TSDB corruption on EFS) |
| Dashboard availability | Grafana `/api/health` blackbox | ≥ 99% |

### Loki (logs)
| SLI | Metric | SLO |
|---|---|---|
| Ingest availability | `loki_request_duration_seconds_count{route="loki_api_v1_push",status_code=~"2.."}` ratio | ≥ 99.5% |
| Ingest latency | push p99 | ≤ 1 s |
| Query latency | `route=~".*query.*"` p95 | ≤ 3 s |
| Log freshness | collector→Loki export lag | ≤ 30 s |

### OTel Collector (the pipeline itself)
| SLI | Metric | SLO |
|---|---|---|
| Availability | `up{job="otel-collector"}` | ≥ 99.5% |
| Data loss | `otelcol_exporter_send_failed_{log_records,spans}` / sent ratio | ≤ 0.1% |
| Queue saturation | `otelcol_exporter_queue_size / queue_capacity` | ≤ 80% |
| Refused data | `otelcol_receiver_refused_*` rate | ≈ 0 |

### Tempo (traces)
| SLI | Metric | SLO |
|---|---|---|
| Ingest availability | `tempo_receiver_refused_spans` vs accepted ratio | ≥ 99.5% |
| Query latency | traceql query p95 | ≤ 3 s |
| Completeness | spans accepted vs collector-exported | ≥ 99% |

### Pyroscope (profiles)
| SLI | Metric | SLO |
|---|---|---|
| Ingest availability | push success ratio (agent-side + server 2xx) | ≥ 99% |
| Query latency | flame graph render p95 | ≤ 5 s |
| Agent overhead | JVM CPU delta with agent on | ≤ 2% (measured, documented) |

## 7.1 Alerting Pipeline (Alertmanager + ntfy + blackbox)
| SLI | Metric | SLO |
|---|---|---|
| **Deadman switch** | `Watchdog` alert (always firing) arriving at ntfy heartbeat topic | gap > 10m = alerting pipeline dead — this is the page-on-absence pattern |
| Notification latency | rule firing → ntfy delivery | p95 ≤ 60 s |
| AM availability | `up{job="alertmanager"}` | ≥ 99.9% (highest of the obs stack — it's the last line) |
| Probe coverage | `probe_success` present for all doc-05 synthetic SLIs | 100% of defined probes |

```yaml
- alert: Watchdog
  expr: vector(1)
  labels: {severity: none}   # routed to heartbeat topic; external check asserts arrival
```

## 8.4 Kroxylicious (governance profile)
| SLI | Metric | SLO |
|---|---|---|
| Proxy availability | `up` + TCP probe :9192 | ≥ 99.9% (it's IN the write path) |
| Added latency | produce p99 via proxy − p99 direct (loadgen A/B) | ≤ 5 ms overhead |
| Encryption success | records encrypted / records proxied | 100% on governed topics |
| KMS dependency | KMS canary (GenerateDataKey) | ≥ 99.5% |

**Composition update:** for governed topics the write path becomes client → proxy → broker: availability = Kroxylicious × Brokers × KMS ≈ 99.9 × 99.9 × 99.5 ≈ **99.3%** honest ceiling — the cost of the governance layer, stated explicitly.

## 8.5 Chaos & Load (validation SLOs — meta-level)
| SLI | Definition | Target |
|---|---|---|
| Detection time | toxic injected → expected alert firing | ≤ 5 min per scenario |
| Recovery time | toxic removed → SLI back in target | ≤ 10 min |
| loadgen steadiness | produce rate stddev | ≤ 10% of baseline |
| Scenario hygiene | active toxics outside a chaos window | 0 (audit-checked) |

```yaml
- alert: TargetDown
  expr: up == 0
  for: 3m
  labels: {severity: warning}
- alert: TSDBCorruption
  expr: increase(prometheus_tsdb_wal_corruptions_total[1h]) > 0
  labels: {severity: critical}
```

## 8. MCP Server
| SLI | Metric (instrument the server with prom-client) | SLO |
|---|---|---|
| Tool success rate | `mcp_tool_calls_total{result="ok"} / mcp_tool_calls_total` | ≥ 99% |
| Tool latency | `mcp_tool_duration_seconds` p95 | ≤ 2 s |
| Guardrail rejections | `mcp_tool_calls_total{result="denied"}` | tracked + audited (never silently dropped) |
| Availability | `up{job="mcp-kafka"}` | ≥ 99% |

## 9. SLO Summary Table (the one-pager)

| System | SLI | SLO (7d) | Error budget | Page? |
|---|---|---|---|---|
| Brokers | write availability | 99.9% | 10m 5s | yes |
| Brokers | produce p99 | ≤ 50 ms | 0.1% slow-window | no (ticket) |
| Brokers | offline partitions | 0 | none | yes |
| Controllers | active controller = 1 | 100% | none | yes |
| Controllers | metadata ops availability | 99.9% | 10m | yes |
| Connect | task availability | 99.5% | 50m | yes |
| Connect | sink freshness p99 | ≤ 120 s | 0.5% | yes |
| Connect | delivery completeness | 99.99% | 1m | yes |
| Schema Registry | API availability | 99.9% | 10m | no |
| LocalStack S3 | canary availability | 99.5% | 50m | no |
| kminion | lag metrics fresh | no gaps > 5m | — | **yes** (blind SLO) |
| Cruise Control | /state availability | 99% | 100m | no |
| Cruise Control | monitored partitions | ≥ 95% | — | no (ticket) |
| Prometheus | scrape completeness | 99.5% | 50m | no |
| **Alertmanager** | availability + deadman | 99.9% | 10m | **yes (page-on-absence)** |
| otel-collector | data loss | ≤ 0.1% | — | no (ticket) |
| Loki | ingest availability | 99.5% | 50m | no |
| Tempo | ingest availability | 99.5% | 50m | no |
| Pyroscope | ingest availability | 99% | 100m | no |
| Kroxylicious* | proxy availability | 99.9% | 10m | yes (write path) |
| Kroxylicious* | added latency p99 | ≤ 5 ms | — | no (ticket) |
| Grafana | health | 99% | 100m | no |
| MCP | tool success | 99% | 100m | no |

\* governance profile only

## 10. Implementation checklist
1. Split `prometheus.yml` scrape jobs per system with proper `job` labels (`kafka-broker`, `kafka-controller`, `kafka-connect`, `mcp-kafka`).
2. Add `rule_files: [rules/*.yml]` + Alertmanager container (`observability` network).
3. Deploy kminion (`kafka-data` + `observability` nets) — JMX alone doesn't give lag-in-seconds; it becomes the source of truth for all freshness SLIs.
4. Add blackbox-exporter for the synthetic probes (metadata ops, SR API, S3 canary, Grafana health, CC `/state`, KMS canary).
5. Deploy **otel-collector** (filelog + OTLP receivers, redaction processor) → Loki + Tempo; wire Grafana derived fields for logs↔traces correlation.
6. Deploy **Alertmanager + ntfy** with the Watchdog deadman switch and inhibition rules; route critical→phone.
7. Deploy Cruise Control: metrics-reporter JAR in brokers, `__CruiseControlMetrics` RF=3, goals config, anomaly detector on / self-healing off.
8. Add **Pyroscope** java agent to Connect (alloc + cpu) — link heap alerts to profile time ranges.
9. Add **loadgen** (steady 50 msg/s baseline) and **toxiproxy** on the Connect→S3 path; codify chaos scenarios as (toxic, expected alert, max detection) tuples in `tools/chaos.sh`.
10. Governance profile: **Kroxylicious** + LocalStack KMS envelope encryption; A/B latency measurement vs direct path.
11. Grafana: one dashboard per system + one **SLO dashboard** rendering the §9 table live with budget-remaining gauges.
12. Recording rules for every SLI ratio (`sli:kafka_write_availability:ratio5m`) so dashboards and alerts share identical definitions.
