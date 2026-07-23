# Kafka Connect image with S3 sink connector (baked via confluent-hub) and
# OpenTelemetry javaagent for trace propagation across Connect tasks.
ARG BASE_IMAGE=confluentinc/cp-kafka-connect
ARG BASE_TAG=7.7.1
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG OTEL_AGENT_VERSION=2.30.0
ARG JMX_EXPORTER_VERSION=1.6.0
ARG PYROSCOPE_AGENT_VERSION=2.8.0
ARG S3_CONNECTOR_VERSION=10.5.25

USER root

# Golden-base rebuild (UBI8 microdnf) — 04-SECURITY-GUARDRAILS §2 phase 6.
RUN microdnf update -y \
 && microdnf clean all

RUN mkdir -p /opt/agents /opt/jmx_exporter

ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar \
    /opt/agents/opentelemetry-javaagent.jar

ADD https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
    /opt/jmx_exporter/jmx_prometheus_javaagent.jar

ADD https://github.com/grafana/pyroscope-java/releases/download/v${PYROSCOPE_AGENT_VERSION}/pyroscope.jar \
    /opt/agents/pyroscope.jar

RUN chmod 0644 /opt/agents/opentelemetry-javaagent.jar \
               /opt/agents/pyroscope.jar \
               /opt/jmx_exporter/jmx_prometheus_javaagent.jar

# Bake S3 sink connector so runtime plugin download is not required.
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-s3:${S3_CONNECTOR_VERSION}

# Vendor-neutral secret sourcing: Kafka Connect's built-in
# FileConfigProvider reads passwords from files instead of env, so the
# secret backing (K8s Secret mount, Vault sidecar, SPIRE issuance,
# ephemeral tmpfs render) is a runtime decision — no vendor JAR baked
# in. See services/kafka-connect/entrypoint-secrets.sh.
RUN mkdir -p /etc/kafka/connect-secrets && chown -R appuser:appuser /etc/kafka/connect-secrets && chmod 0700 /etc/kafka/connect-secrets
COPY --chmod=0755 entrypoint-secrets.sh /usr/local/bin/entrypoint-secrets.sh

COPY config/jmx/kafka-config.yml /opt/jmx_exporter/kafka-config.yml

USER appuser

ENTRYPOINT ["/usr/local/bin/entrypoint-secrets.sh"]
