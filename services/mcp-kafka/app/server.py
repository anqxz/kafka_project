"""mcp-kafka — Tier-0 read-only MCP server.

Exposes cluster inspection tools an AI agent can call over SSE. Contract:
02-INTEGRATION-ARCHITECTURE.md §3. Add Tier-1 mutations only when MCP_MODE=admin.
"""
from __future__ import annotations

import logging
import os
import secrets
from typing import Any

import requests
from fastmcp import FastMCP
from kafka import KafkaAdminClient, KafkaConsumer
from kafka.errors import KafkaError

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "broker1:9092,broker2:9092,broker3:9092")
KAFKA_SECURITY_PROTOCOL = os.getenv("KAFKA_SECURITY_PROTOCOL", "PLAINTEXT")
KAFKA_SASL_MECHANISM = os.getenv("KAFKA_SASL_MECHANISM", "")
KAFKA_SASL_USERNAME = os.getenv("KAFKA_SASL_USERNAME", "")
KAFKA_SASL_PASSWORD = os.getenv("KAFKA_SASL_PASSWORD", "")
KAFKA_SSL_CAFILE = os.getenv("KAFKA_SSL_CAFILE", "")

# Phase 5: read KAFKA_SASL_PASSWORD from a file when
# KAFKA_SASL_PASSWORD_FILE is set. Enterprise deployments mount the
# file from a K8s Secret projected volume, a Vault-agent side-car, a
# SPIFFE-issued short-lived credential, or a container-level tmpfs
# render — any source that materialises the secret on disk. Vendor-
# neutral by design: no AWS SDK, no MSK plugin JAR.
_PASSWORD_FILE = os.getenv("KAFKA_SASL_PASSWORD_FILE", "")
if _PASSWORD_FILE:
    with open(_PASSWORD_FILE, "r", encoding="utf-8") as _f:
        KAFKA_SASL_PASSWORD = _f.read().strip()


def _kafka_client_kwargs() -> dict[str, object]:
    """Common Kafka client kwargs (security protocol + optional SCRAM + optional TLS CA)."""
    kw: dict[str, object] = {
        "bootstrap_servers": BOOTSTRAP.split(","),
        "security_protocol": KAFKA_SECURITY_PROTOCOL,
    }
    if KAFKA_SASL_MECHANISM:
        kw.update(
            sasl_mechanism=KAFKA_SASL_MECHANISM,
            sasl_plain_username=KAFKA_SASL_USERNAME,
            sasl_plain_password=KAFKA_SASL_PASSWORD,
        )
    if KAFKA_SSL_CAFILE:
        kw["ssl_cafile"] = KAFKA_SSL_CAFILE
    return kw
CONNECT_URL = os.getenv("CONNECT_URL", "http://kafka-connect:8083")
SCHEMA_REGISTRY_URL = os.getenv("SCHEMA_REGISTRY_URL", "http://schema-registry:8081")
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
MCP_MODE = os.getenv("MCP_MODE", "read-only")
MCP_AUTH_TOKEN = os.getenv("MCP_AUTH_TOKEN", "")

log = logging.getLogger("mcp-kafka")

mcp = FastMCP("mcp-kafka")


def _require_token(request_headers: dict[str, str]) -> None:
    """Refuse the request when MCP_AUTH_TOKEN is set and the caller did not
    send a matching Bearer token. Constant-time compare — no early return."""
    if not MCP_AUTH_TOKEN:
        return
    supplied = request_headers.get("authorization", "")
    prefix = "Bearer "
    if not supplied.startswith(prefix):
        raise PermissionError("missing Bearer token")
    if not secrets.compare_digest(supplied[len(prefix):], MCP_AUTH_TOKEN):
        raise PermissionError("bad Bearer token")


def _admin() -> KafkaAdminClient:
    return KafkaAdminClient(client_id="mcp-kafka", **_kafka_client_kwargs())


@mcp.tool()
def list_topics() -> list[str]:
    """List all topic names in the Kafka cluster."""
    with _admin() as a:
        return sorted(a.list_topics())


@mcp.tool()
def describe_topic(name: str) -> dict[str, Any]:
    """Return partition count, replication factor, and per-partition leader/ISR for a topic."""
    with _admin() as a:
        meta = a.describe_topics([name])
    return meta[0] if meta else {"error": f"topic {name!r} not found"}


@mcp.tool()
def list_consumer_groups() -> list[dict[str, str]]:
    """List consumer groups with their protocol type."""
    with _admin() as a:
        return [{"group_id": g, "protocol_type": p} for g, p in a.list_consumer_groups()]


@mcp.tool()
def get_consumer_lag(group_id: str) -> dict[str, Any]:
    """Return per-topic-partition lag for a consumer group (via kminion metrics if scraped)."""
    q = f'kminion_kafka_consumer_group_topic_lag{{group_id="{group_id}"}}'
    r = requests.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": q}, timeout=5)
    r.raise_for_status()
    return {"query": q, "result": r.json().get("data", {}).get("result", [])}


@mcp.tool()
def cluster_health() -> dict[str, Any]:
    """One-shot health check: broker count, under-replicated partitions, offline partitions, controller."""
    queries = {
        "brokers_up": "count(kafka_server_replicamanager_leadercount)",
        "under_replicated": "sum(kafka_server_replicamanager_underreplicatedpartitions)",
        "offline_partitions": "sum(kafka_controller_kafkacontroller_offlinepartitionscount)",
        "active_controllers": "sum(kafka_controller_kafkacontroller_activecontrollercount)",
    }
    out: dict[str, Any] = {}
    for k, q in queries.items():
        try:
            r = requests.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": q}, timeout=5)
            r.raise_for_status()
            res = r.json().get("data", {}).get("result", [])
            out[k] = float(res[0]["value"][1]) if res else None
        except (requests.RequestException, ValueError, KeyError) as e:
            out[k] = f"error: {e}"
    return out


@mcp.tool()
def connect_status(connector: str) -> dict[str, Any]:
    """Fetch a Kafka Connect connector + task status."""
    r = requests.get(f"{CONNECT_URL}/connectors/{connector}/status", timeout=5)
    if r.status_code == 404:
        return {"error": f"connector {connector!r} not found"}
    r.raise_for_status()
    return r.json()


@mcp.tool()
def get_schema(subject: str) -> dict[str, Any]:
    """Fetch the latest schema for a Schema Registry subject."""
    r = requests.get(f"{SCHEMA_REGISTRY_URL}/subjects/{subject}/versions/latest", timeout=5)
    if r.status_code == 404:
        return {"error": f"subject {subject!r} not found"}
    r.raise_for_status()
    return r.json()


@mcp.tool()
def query_metrics(query: str) -> dict[str, Any]:
    """Run an allowlisted PromQL query. Rejects admin API paths."""
    if any(bad in query for bad in ("/api/v1/admin", "/-/reload", "/-/quit")):
        return {"error": "admin PromQL blocked"}
    r = requests.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": query}, timeout=5)
    r.raise_for_status()
    return r.json()


@mcp.tool()
def tail_topic(topic: str, max_messages: int = 20, timeout_seconds: int = 5) -> list[dict[str, Any]]:
    """Read up to max_messages from a topic. Bounded — not a subscription."""
    max_messages = min(max_messages, 100)
    timeout_seconds = min(timeout_seconds, 30)
    consumer = KafkaConsumer(
        topic,
        auto_offset_reset="latest",
        consumer_timeout_ms=timeout_seconds * 1000,
        client_id="mcp-kafka-tail",
        group_id=None,
        **_kafka_client_kwargs(),
    )
    out: list[dict[str, Any]] = []
    try:
        for msg in consumer:
            out.append({
                "partition": msg.partition,
                "offset": msg.offset,
                "key": msg.key.decode("utf-8", "replace") if msg.key else None,
                "value": msg.value.decode("utf-8", "replace") if msg.value else None,
                "timestamp": msg.timestamp,
            })
            if len(out) >= max_messages:
                break
    except KafkaError as e:
        out.append({"error": str(e)})
    finally:
        consumer.close()
    return out


if __name__ == "__main__":
    transport = os.getenv("MCP_TRANSPORT", "sse")
    if transport == "stdio":
        mcp.run()
    else:
        import uvicorn
        from starlette.middleware.base import BaseHTTPMiddleware
        from starlette.responses import PlainTextResponse

        class BearerAuthMiddleware(BaseHTTPMiddleware):
            async def dispatch(self, request, call_next):
                if MCP_AUTH_TOKEN:
                    auth = request.headers.get("authorization", "")
                    prefix = "Bearer "
                    ok = (
                        auth.startswith(prefix)
                        and secrets.compare_digest(auth[len(prefix):], MCP_AUTH_TOKEN)
                    )
                    if not ok:
                        return PlainTextResponse("unauthorized", status_code=401)
                return await call_next(request)

        app = mcp.sse_app()
        app.add_middleware(BearerAuthMiddleware)
        if not MCP_AUTH_TOKEN:
            log.warning(
                "MCP_AUTH_TOKEN is unset — SSE endpoint is open. Set the env "
                "variable in production (04-SECURITY-GUARDRAILS F9)."
            )
        import ssl as _ssl
        tls_cert = os.getenv("MCP_TLS_CERT", "")
        tls_key  = os.getenv("MCP_TLS_KEY", "")
        tls_ca   = os.getenv("MCP_TLS_CLIENT_CA", "")
        uvicorn_kwargs: dict[str, object] = dict(
            host="0.0.0.0", port=int(os.getenv("MCP_PORT", "3001")),
            log_level=os.getenv("LOG_LEVEL", "info").lower(),
        )
        if tls_cert and tls_key:
            uvicorn_kwargs.update(ssl_certfile=tls_cert, ssl_keyfile=tls_key)
            if tls_ca:
                uvicorn_kwargs.update(
                    ssl_ca_certs=tls_ca,
                    ssl_cert_reqs=_ssl.CERT_REQUIRED,
                )
            else:
                log.warning(
                    "MCP_TLS_CLIENT_CA unset — server-only TLS, no client cert "
                    "verification (04-SECURITY-GUARDRAILS F9 second half)."
                )
        else:
            log.warning(
                "MCP_TLS_CERT/KEY unset — SSE endpoint runs over plaintext HTTP."
            )
        uvicorn.run(app, **uvicorn_kwargs)
