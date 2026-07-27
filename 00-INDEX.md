# Architecture & Operations Docs — Kafka KRaft Cluster on Docker with MCP

Design documentation for evolving `kafka_project` from a working lab into a platform-engineering showcase: segmented networks, governed integration, explicit data contracts, security guardrails, and SLO-driven observability — with an MCP control plane so AI agents can diagnose the cluster through typed, guardrailed tools.

| Doc | Contents |
|---|---|
| [01 — Network Architecture](01-NETWORK-ARCHITECTURE.md) | Current flat topology → 4-zone segmentation (`kafka-quorum` / `kafka-data` / `observability` / `edge`), listener & port map, loopback-only admin surfaces |
| [02 — Integration Architecture](02-INTEGRATION-ARCHITECTURE.md) | Component contracts, startup ordering with healthchecks, MCP server design: tool tiers, deployment, interaction sequences |
| [03 — Data Flow Architecture](03-DATA-FLOW-ARCHITECTURE.md) | Produce→S3 path with delivery semantics per hop, KRaft metadata flow, schema flow, metrics flow, failure propagation map |
| [04 — Security Guardrails](04-SECURITY-GUARDRAILS.md) | 11 current-state findings, 6-phase remediation (network → SASL/SCRAM → ACLs → TLS → secrets → supply chain), MCP-specific guardrails, negative-test smoke suite |
| [05 — Observability, SLI/SLO](05-OBSERVABILITY-SLO-SLI.md) | Full metric inventory per system, 13 SLOs with error budgets, PromQL alert rules, dependency-composition math, implementation checklist |

## Implementation roadmap

### Foundational sequence (PR 1 – PR 11) — ✅ all merged

| PR | Scope | Landed |
|---|---|---|
| 1 | 4-zone network segmentation | ✅ |
| 2 | Observability + platform stack (kminion, LGTM(P), Alertmanager, Blackbox, CC, ntfy) | ✅ |
| 3 | Healthchecks + pinned images | ✅ |
| 4 | Security smoke rules + failure-map alerts | ✅ |
| 5 | Cruise Control tuning + metrics reporter | ✅ |
| 6 | Loadgen + toxiproxy chaos harness | ✅ |
| 7 | MCP server — Tier-0 read-only (search_logs, get_trace, get_profile, cluster_balance_status) | ✅ |
| 8 | SASL/SCRAM + ACLs (later superseded by mTLS in PR 9-family) | ✅ |
| 9 | Kroxylicious governance profile + LocalStack KMS envelope encryption | ✅ |
| 10 | Schema Registry Avro on `events` + BACKWARD compatibility | ✅ |
| 11 | Security smoke tests in CI + negative-test suite | ✅ |

### mTLS retrofit (post-PR 8) — ✅ merged

SASL/SCRAM from PR 8 was replaced by end-to-end mTLS through a follow-up
series (PRs 9, 10, 11, 12, 24, 30, 33, 41, 48, 50, 51, 54, 57): PKI + SSL
listeners, mTLS clients (kminion, akhq, schema-registry, kafka-connect,
mcp-kafka), HTTPS on CC / Connect / SR REST, ACL alignment, JDK-17 bump
for CC 2.5.146. Contract lives in [`04-SECURITY-GUARDRAILS.md`](04-SECURITY-GUARDRAILS.md).

### Continuous hardening

Post-PR 11 the roadmap moves to one-bump-per-PR security refresh
(`chore(security)` prefix): grafana 11→13, prometheus v2→v3, tempo v2→v3,
step-ca 0.26→0.30, cruise-control 2.5.138→2.5.146, kroxylicious 0.10→0.11,
plus pip / gh-action dependabot chain. Convention:
- One version bump per PR.
- `.env` + `Dockerfile` `ARG` in parity.
- Wait for CI (build + Trivy + gitleaks + digest-drift gate) before merge.
- Bundle only safe patch groups (never mix minor bumps across services).
