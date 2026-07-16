# Continuous synthetic Kafka producer. Multi-stage: deps in builder, only
# the venv + app copied into slim runtime. OTel auto-instrumentation is
# activated by the opentelemetry-instrument wrapper.
ARG PYTHON_TAG=3.13-slim

FROM python:${PYTHON_TAG} AS builder
WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:${PYTHON_TAG}
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    OTEL_SERVICE_NAME=loadgen \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 \
    OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_LOGS_EXPORTER=otlp \
    OTEL_METRICS_EXPORTER=none \
    OTEL_PYTHON_LOG_CORRELATION=true \
    OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true \
    LOADGEN_TOPIC=events \
    LOADGEN_RATE=5 \
    LOADGEN_DURATION=0
COPY --from=builder /install /usr/local
WORKDIR /app
COPY app/ /app/
CMD ["opentelemetry-instrument", "python", "loadgen.py"]
