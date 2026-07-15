# Architecture & Operations Docs — Kafka KRaft Cluster on Docker with MCP

Design documentation for evolving `kafka_project` from a working lab into a platform-engineering showcase: segmented networks, governed integration, explicit data contracts, security guardrails, and SLO-driven observability — with an MCP control plane so AI agents can diagnose the cluster through typed, guardrailed tools.

| Doc | Contents |
|---|---|
| [01 — Network Architecture](01-NETWORK-ARCHITECTURE.md) | Current flat topology → 4-zone segmentation (`kafka-quorum` / `kafka-data` / `observability` / `edge`), listener & port map, loopback-only admin surfaces |
| [02 — Integration Architecture](02-INTEGRATION-ARCHITECTURE.md) | Component contracts, startup ordering with healthchecks, MCP server design: tool tiers, deployment, interaction sequences |
| [03 — Data Flow Architecture](03-DATA-FLOW-ARCHITECTURE.md) | Produce→S3 path with delivery semantics per hop, KRaft metadata flow, schema flow, metrics flow, failure propagation map |
| [04 — Security Guardrails](04-SECURITY-GUARDRAILS.md) | 11 current-state findings, 6-phase remediation (network → SASL/SCRAM → ACLs → TLS → secrets → supply chain), MCP-specific guardrails, negative-test smoke suite |
| [05 — Observability, SLI/SLO](05-OBSERVABILITY-SLO-SLI.md) | Full metric inventory per system, 13 SLOs with error budgets, PromQL alert rules, dependency-composition math, implementation checklist |

## Implementation roadmap (suggested PR sequence)

**Status:**
- PR 1 in flight on branch `feat/pr1-network-segmentation` — runbook + verification in [doc 01 §6](01-NETWORK-ARCHITECTURE.md#6-pr-1--implementation-runbook).
- **PR 2 in flight** on branch `feat/pr2-observability-stack` — runbook in [doc 02 §7](02-INTEGRATION-ARCHITECTURE.md#7-pr-2-runbook--observability--platform-stack).

### Applying PR 1 locally

```bash
git switch feat/pr1-network-segmentation
cd clusters
docker compose down          # ONE-TIME: releases the old flat network
docker compose up -d
```

Then run the verification block in [doc 01 §6.3](01-NETWORK-ARCHITECTURE.md#63-verification-checklist) and paste the output into the PR. Every check must pass — any `LEAK` line is a merge-blocker.

### PR sequence

1. **PR 1 — Networks:** apply doc 01 compose changes (pure infra, no app config). *(in flight)*
2. **PR 2 — Observability + platform stack:** kminion, OTel collector, Loki, Tempo, Pyroscope, Alertmanager, Blackbox Exporter, Cruise Control, ntfy. *(in flight — [§7 runbook](02-INTEGRATION-ARCHITECTURE.md#7-pr-2-runbook--observability--platform-stack))*
3. **PR 3 — Healthchecks + pinned images:** doc 02 §4 + doc 04 F8.
4. **PR 4 — Security smoke tests:** rule files from doc 05 §4, alerting on doc 03 failure map.
5. **PR 5 — Cruise Control tuning:** metrics-reporter JAR in brokers, CC goals config, anomaly detection (self-healing off) — doc 02 §3.5.
6. **PR 6 — Validation:** **loadgen** baseline + **toxiproxy** chaos scenarios asserting the doc-03 failure map (detection ≤ 5 min) — doc 02 §3.11.
7. **PR 7 — MCP server (read-only Tier 0):** doc 02 §3, including `search_logs`, `get_trace`, `get_profile`, `cluster_balance_status` — the headline feature.
8. **PR 8 — SASL/SCRAM + ACLs:** doc 04 phases 2–3, principals for mcp/kminion/cruise-control/loadgen.
9. **PR 9 — Governance profile:** **Kroxylicious** + LocalStack KMS envelope encryption, A/B latency SLO — doc 02 §3.10 / doc 03 §4.6.
10. **PR 10 — Schema Registry integration:** Avro on `events`, BACKWARD compatibility (doc 03 §3).
11. **PR 11 — Security smoke tests in CI:** doc 04 §4, including CC/toxiproxy/ntfy/encryption negative tests.
