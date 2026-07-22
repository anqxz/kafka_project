"""Continuous synthetic Kafka producer with OTel auto-instrumentation.

Env-driven — no interactive prompts. Publishes JSON events to LOADGEN_TOPIC at
LOADGEN_RATE msgs/s. Traces + logs flow to the OTel collector via the standard
OTEL_EXPORTER_OTLP_ENDPOINT.
"""
from __future__ import annotations

import json
import logging
import os
import random
import signal
import sys
import time
from datetime import datetime, timezone

from kafka import KafkaProducer
from opentelemetry import trace
from opentelemetry.propagate import inject

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "broker1:9096,broker2:9096,broker3:9096")
SECURITY_PROTOCOL = os.getenv("KAFKA_SECURITY_PROTOCOL", "SSL")
SSL_CAFILE = os.getenv("KAFKA_SSL_CAFILE", "/certs/ca/ca-bundle.pem")
SSL_CERTFILE = os.getenv("KAFKA_SSL_CERTFILE", "/certs/pem/loadgen/tls.crt")
SSL_KEYFILE = os.getenv("KAFKA_SSL_KEYFILE", "/certs/pem/loadgen/tls.key")
TOPIC = os.getenv("LOADGEN_TOPIC", "events")
RATE = float(os.getenv("LOADGEN_RATE", "5"))
DURATION = float(os.getenv("LOADGEN_DURATION", "0"))  # 0 = run until SIGTERM

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s otelSpanID=%(otelSpanID)s "
           "otelTraceID=%(otelTraceID)s %(message)s",
)
log = logging.getLogger("loadgen")
tracer = trace.get_tracer("loadgen")


def _traceparent_headers() -> list[tuple[str, bytes]]:
    """W3C traceparent as Kafka record headers (03-DATA-FLOW §4.2)."""
    carrier: dict[str, str] = {}
    inject(carrier)
    return [(k, v.encode("utf-8")) for k, v in carrier.items()]

EVENT_TYPES = ["user_login", "page_view", "purchase", "add_to_cart", "search"]
USERS = ["alice", "bob", "charlie", "david", "emma", "frank"]

_running = True


def _stop(*_: object) -> None:
    global _running
    log.info("SIGTERM received, draining")
    _running = False


signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)


def make_event(i: int) -> dict:
    return {
        "id": i,
        "type": random.choice(EVENT_TYPES),
        "user": random.choice(USERS),
        "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def main() -> int:
    producer_kwargs: dict[str, object] = dict(
        bootstrap_servers=BOOTSTRAP.split(","),
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8") if k else None,
        acks="all",
        retries=3,
        compression_type="gzip",
        client_id="loadgen",
        security_protocol=SECURITY_PROTOCOL,
        ssl_cafile=SSL_CAFILE,
        ssl_certfile=SSL_CERTFILE,
        ssl_keyfile=SSL_KEYFILE,
        ssl_check_hostname=True,
    )
    producer = KafkaProducer(**producer_kwargs)
    log.info("loadgen started", extra={"bootstrap": BOOTSTRAP, "topic": TOPIC, "rate": RATE})

    delay = 1.0 / RATE if RATE > 0 else 0
    start = time.monotonic()
    i = 0
    try:
        while _running:
            i += 1
            evt = make_event(i)
            with tracer.start_as_current_span("events send") as span:
                span.set_attribute("messaging.system", "kafka")
                span.set_attribute("messaging.destination.name", TOPIC)
                span.set_attribute("messaging.kafka.message.key", evt["user"])
                producer.send(TOPIC, key=evt["user"], value=evt, headers=_traceparent_headers())
            if i % 100 == 0:
                log.info("sent batch", extra={"count": i})
            if DURATION and (time.monotonic() - start) >= DURATION:
                log.info("duration reached, stopping", extra={"duration": DURATION})
                break
            if delay:
                time.sleep(delay)
    finally:
        producer.flush(timeout=10)
        producer.close()
        log.info("loadgen stopped", extra={"total_sent": i})
    return 0


if __name__ == "__main__":
    sys.exit(main())
