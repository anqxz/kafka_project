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

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "broker1:9092,broker2:9092,broker3:9092")
SASL_MECHANISM = os.getenv("KAFKA_SASL_MECHANISM", "")
SASL_USERNAME = os.getenv("KAFKA_SASL_USERNAME", "")
SASL_PASSWORD = os.getenv("KAFKA_SASL_PASSWORD", "")
SECURITY_PROTOCOL = os.getenv("KAFKA_SECURITY_PROTOCOL", "PLAINTEXT")
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
    )
    if SASL_MECHANISM:
        producer_kwargs.update(
            sasl_mechanism=SASL_MECHANISM,
            sasl_plain_username=SASL_USERNAME,
            sasl_plain_password=SASL_PASSWORD,
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
