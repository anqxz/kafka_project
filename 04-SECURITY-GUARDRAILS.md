# 04 — Security Guardrails

> Threat model, current-state findings, and a phased path from the lab-safe
> baseline (network segmentation) to a production-shaped posture
> (SASL/SCRAM → ACLs → TLS → secrets → supply chain).

## 0. Threat model

**In scope.** A single-tenant lab running rootless podman on one developer
workstation. The stack must be safe to run without exposing anything to the
LAN or the public internet.

**Adversaries considered.**

| # | Actor | Vector | Realistic in lab? |
|---|---|---|---|
| A1 | Coworker on the same laptop | shell as `aqueiroz` | yes |
| A2 | Malicious npm/pip transitive dep | supply chain into a helper script | yes |
| A3 | Cross-container escape via a vulnerable image | rootless podman bounds blast radius but exists | yes |
| A4 | LAN attacker | ports removed / loopback only (doc 01) | no by design |
| A5 | Public internet | no host has a public IP; edge is 127.0.0.1 only | no by design |

**Out of scope.** Full production posture (multi-tenant, HSM-backed KMS,
customer PII flows, WAF, DDoS). Where a lab decision would diverge from
production, it is called out explicitly under §5.

**Assumptions.**

- Host uid 1001 owns the whole stack; podman socket is rootless.
- All host bindings live on `127.0.0.1`. Any deviation is a finding.
- Data-plane cleartext (PLAINTEXT listeners) is acceptable inside the
  four compose networks; nothing may cross the edge without the guardrails
  in §2.

## 1. Current-state findings (F1–F11)

Severity is scored against the production target, not against the lab
scope — a "critical" here does not necessarily mean "unsafe today", it
means "must be closed before this stack leaves the laptop".

| ID | Area | Finding | Severity | Current state | Fix phase |
|---|---|---|---|---|---|
| F1  | Auth (brokers) | Kafka listeners are `PLAINTEXT`; any container on `kafka-data` can publish or consume as any principal. | Critical | Accepted for lab. `KAFKA_ALLOW_PLAINTEXT_LISTENER=yes` set explicitly so it is greppable. | 2 |
| F2  | Authz (topics) | No ACLs. Every principal (real or forged) has `ALL` on every topic. | Critical | Not enforced. AKHQ, kminion, connect, mcp all effectively `super.user`. | 3 |
| F3  | UI credentials | Grafana ships with `admin/admin`; ntfy topic path acts as the only "auth". | High | Edge-bound to 127.0.0.1. Password not rotated. | 5 |
| F4  | Connect REST | Kafka Connect REST is unauthenticated and can create/delete connectors. | High | Loopback-bound (127.0.0.1:8083). Anyone with a shell on the host owns Connect. | 2 |
| F5  | Schema Registry | Unauthenticated REST + Kafka backing store. Anyone on `kafka-data` can register/delete subjects. | Medium | Loopback-bound (127.0.0.1:8081). Subjects unused today, so blast radius small. | 2 |
| F6  | LocalStack Lambda executor | `LAMBDA_EXECUTOR=docker-reuse` requires `/var/run/docker.sock` — a container escape primitive. | High | Disabled under rootless (no host socket). Lab-accepted if re-enabled. | 5 |
| F7  | AWS creds in env | `AWS_ACCESS_KEY_ID=test` / `AWS_SECRET_ACCESS_KEY=test` set at compose env for Connect and mcp. | Medium | Lab-only credentials, but the *pattern* leaks into production. | 5 |
| F8  | Supply chain (images) | Historically several observability containers rode `:latest`. | High | All 25 services now pinned via `clusters/.env`; no runtime pulls. SBOM + cosign not yet in place. | 6 |
| F9  | MCP surface | `mcp-kafka` exposes SSE on `:3001` with no auth. | High | `MCP_MODE=read-only` by default; Tier-1 mutations are unimplemented, so today only Tier-0 (`list_topics`, `tail_topic`, …) is reachable. Loopback-bound. | 2 (basic auth) then 4 (mTLS) |
| F10 | Cruise Control REST | `:9095` unauthenticated; `POST /rebalance` is a fleet-wide operation. | High | Loopback-bound. Dry-run-first policy is doc-level only, no gate in code. | 2 + policy in MCP layer |
| F11 | ntfy webhook token | Alertmanager posts to `http://ntfy/kafka-alerts-c3f8a2d1` — the path is the only auth. | Medium | Token is plaintext in `alertmanager.yml` and `docker-compose.yml`. Rotating it is a config edit + restart. | 5 |

## 1.1 Auxiliary findings (F12–F16)

Referenced from adjacent docs; not part of the "11 core" but tracked here.

| ID | Reference | Note |
|---|---|---|
| F12 | 01-NETWORK §3 | OTel `filelog` receiver would need `/var/lib/docker/containers` mounted — infeasible under rootless podman. Log ingestion via OTLP push from apps only. |
| F13 | Cross-cutting | No mTLS between components. Everything on the four internal networks trusts the network. |
| F14 | 01-NETWORK §4 | Toxiproxy `:8474` is a mutating API. Loopback-bound today; add token auth in phase 5. |
| F15 | 02-INTEGRATION §3.4, 03-DATA §4.1 | OTel Collector `transform` processor is the single PII/secret chokepoint. Today strips `password`, `secret`, `token`, `apikey` keys before export to Loki. Expand list + audit before any real user data flows. |
| F16 | 01-NETWORK §4 | Same as F14; called out separately because it is enforced by `ports:` binding in compose, not by any application-level check. |

## 2. Six-phase remediation

Each phase is one PR; every phase leaves the stack bootable and green.

### Phase 1 — Network segmentation ✅ done

Four compose networks isolate the metadata plane (`kafka-quorum`), the
data plane (`kafka-data`), the observability plane, and the host edge.
Nothing leaves the laptop. Documented in [01-NETWORK-ARCHITECTURE.md].

### Phase 2 — SASL/SCRAM on brokers + REST auth

- Add `SASL_PLAINTEXT` listener on brokers alongside PLAINTEXT during
  cut-over, then flip clients one by one.
- Create SCRAM-SHA-512 principals: `mcp`, `kminion`, `connect`,
  `schema-registry`, `cruise-control`, `loadgen`, `akhq`.
- Kafka Connect REST → basic auth via `rest.extension.classes` +
  `PropertyFileLoginModule`.
- Schema Registry → HTTP basic + JAAS.
- Cruise Control → `webserver.security.enable=true` + basic auth.
- MCP-Kafka → shared-token (`Authorization: Bearer …`) SSE guard.

### Phase 3 — ACLs

- Deny by default via `super.users=User:admin` only.
- Least-privilege ACL matrix per principal (matrix goes here once phase
  2 lands).
- CC gets `Cluster:Alter` + `Cluster:Describe` only; no per-topic write.
- MCP-Kafka Tier-0 gets `Cluster:Describe` + `Topic:Describe`; Tier-1
  additions gated by `MCP_MODE=admin`.

### Phase 4 — TLS

- Broker listeners upgrade PLAINTEXT → `SASL_SSL`.
- Generate a lab CA under `services/tls/`; issue per-service certs at
  build time.
- OTLP HTTP endpoint (currently `http://otel-collector:4318`) becomes
  `https://` inside the observability network.
- mTLS on the MCP SSE endpoint (F9 second half).

### Phase 5 — Secrets management

- Move `AWS_*` and any DB creds to LocalStack Secrets Manager.
- Connect / Schema Registry / MCP resolve via
  `config.providers=secretsmanager` (Confluent `ConfigProvider`).
- Rotate the ntfy topic path on every deploy; sourced from Secrets
  Manager (fixes F11).
- Grafana admin password read from a compose secret, not an env literal
  (fixes F3 first half).

### Phase 6 — Supply chain

- Trivy or Grype scan every `services/*/Dockerfile` in CI.
- SBOM per image (Syft) attached as a workflow artifact.
- `cosign sign` + `cosign verify` for anything pushed to a registry.
- Renovate/Dependabot on `.env` version pins.
- `docker compose config --resolve-image-digests` in CI to detect drift.

## 3. MCP-specific guardrails

MCP-Kafka is the highest-blast-radius component in the stack (it can
touch every subsystem), so it gets its own control set.

- **Read-only by default.** `MCP_MODE=read-only` disables every Tier-1
  entry point at import time. Flipping the mode is a compose edit + full
  restart; there is no dynamic upgrade path.
- **Tool allowlist per tier** (see [02-INTEGRATION-ARCHITECTURE.md §3.2]).
  Tier-1 tools live behind an `if MCP_MODE == "admin"` gate; the
  `admin` build also refuses to expose `delete_topic` on `_*` internal
  topics, ACL mutation, or arbitrary PromQL admin endpoints.
- **Dry-run first.** Any operation that changes cluster state defaults
  to `dry_run=True`; the caller must explicitly pass `dry_run=False`.
- **Audit log.** Every Tier-1 invocation writes a structured JSON line
  through the OTel logs exporter — Loki becomes the audit trail.
- **Rate limits.** Loose per-tool budget enforced in-process; a real
  deployment adds a Redis token bucket in front of the SSE endpoint.
- **Bounded `tail_topic`.** Ephemeral consumer group
  (`mcp-tail-<uuid>`, `auto.offset.reset=latest`, `max_messages ≤ 100`,
  `timeout_seconds ≤ 30`); it cannot disturb committed offsets of real
  consumers (03-DATA §5 covers this in detail).

## 4. Negative-test smoke suite

Every one of these is a failing test today and a passing test after the
matching phase lands. Once wired to CI, a broken guardrail turns into a
red build.

| Test | Expectation | Phase gating |
|---|---|---|
| `kafka-console-producer` with wrong SASL creds | denied | 2 |
| `kafka-console-producer` for a topic the principal lacks `Write` on | denied | 3 |
| `POST /connectors` from a non-loopback IP | connection refused | 1 (already true) |
| Plaintext `kcat` against a `SASL_SSL`-only listener | handshake failure | 4 |
| `docker exec … env` containing `AWS_SECRET_ACCESS_KEY=<literal>` | not present | 5 |
| Grafana login with `admin/admin` | denied | 5 |
| ntfy webhook POST with the wrong topic path | 404 | 5 (rotation) |
| Cruise Control `/rebalance` from a non-loopback caller | denied | 2 |
| Kroxylicious in "encryption" profile: `kafka-console-consumer` bypassing the proxy | reads ciphertext only | future (§5) |
| PII string in a log line (`password=hunter2`) | attribute stripped by OTel transform before Loki | already true (F15) |
| `docker inspect` on a running container | image digest matches SBOM manifest | 6 |

## 5. Deferred / accepted lab risks

The following are explicitly *decisions*, not oversights:

- **PLAINTEXT data plane inside the lab networks.** Cost of turning on
  SASL for every dev iteration outweighs the risk while nothing crosses
  the edge. Reversed the moment we run outside the workstation.
- **`admin/admin` on Grafana.** Loopback only, no anonymous access.
  Rotated once phase 5 lands.
- **`test/test` for LocalStack AWS creds.** LocalStack itself does not
  validate them; treating them as secrets would only add friction.
- **No mTLS between observability containers.** Their networks are
  `internal: true`; nothing outside the observability net can even reach
  them. Reconsidered in phase 4.
- **No RecordEncryption yet on Kroxylicious.** Filter chain reserved for
  a follow-up PR; the pass-through profile is the current default.

## 6. References

- [00-INDEX.md](00-INDEX.md)
- [01-NETWORK-ARCHITECTURE.md](01-NETWORK-ARCHITECTURE.md) — the isolation floor every finding above rides on.
- [02-INTEGRATION-ARCHITECTURE.md §3](02-INTEGRATION-ARCHITECTURE.md) — MCP tool contract this doc guards.
- [03-DATA-FLOW-ARCHITECTURE.md §4.1, §4.6](03-DATA-FLOW-ARCHITECTURE.md) — PII redaction chokepoint (F15) and encrypted-write path.
- [05-OBSERVABILITY-SLO-SLI.md](05-OBSERVABILITY-SLO-SLI.md) — the alert pipeline (Watchdog + friends) that makes broken guardrails visible.
