# Schema Registry with OpenTelemetry javaagent and JMX exporter.
ARG BASE_IMAGE=confluentinc/cp-schema-registry
ARG BASE_TAG=7.7.1
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG OTEL_AGENT_VERSION=2.10.0
ARG JMX_EXPORTER_VERSION=1.0.1
ARG PYROSCOPE_AGENT_VERSION=2.8.0

USER root

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

COPY config/jmx/kafka-config.yml /opt/jmx_exporter/kafka-config.yml

USER appuser
