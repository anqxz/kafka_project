# KRaft controller image — JMX exporter + OpenTelemetry javaagent baked in.
# Controllers do not produce records, so no Cruise Control metrics reporter.
ARG BASE_IMAGE=confluentinc/cp-kafka
ARG BASE_TAG=7.7.1
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG JMX_EXPORTER_VERSION=1.0.1
ARG OTEL_AGENT_VERSION=2.10.0
ARG PYROSCOPE_AGENT_VERSION=2.8.0

USER root

# Golden-base rebuild (UBI8 microdnf) — 04-SECURITY-GUARDRAILS §2 phase 6.
RUN microdnf update -y \
 && microdnf clean all

RUN mkdir -p /opt/agents /opt/jmx_exporter

ADD https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
    /opt/jmx_exporter/jmx_prometheus_javaagent.jar

ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar \
    /opt/agents/opentelemetry-javaagent.jar

ADD https://github.com/grafana/pyroscope-java/releases/download/v${PYROSCOPE_AGENT_VERSION}/pyroscope.jar \
    /opt/agents/pyroscope.jar

RUN chmod 0644 /opt/jmx_exporter/jmx_prometheus_javaagent.jar \
               /opt/agents/opentelemetry-javaagent.jar \
               /opt/agents/pyroscope.jar

COPY config/jmx/kafka-config.yml /opt/jmx_exporter/kafka-config.yml
COPY --chmod=0755 entrypoint-jmx-tls.sh /usr/local/bin/entrypoint-jmx-tls.sh

USER appuser

ENTRYPOINT ["/usr/local/bin/entrypoint-jmx-tls.sh"]
