# Kafka broker image with JMX exporter, OpenTelemetry javaagent, and
# Cruise Control metrics reporter baked in. Config lives under config/.
ARG BASE_IMAGE=confluentinc/cp-kafka
ARG BASE_TAG=7.7.1
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG JMX_EXPORTER_VERSION=1.0.1
ARG OTEL_AGENT_VERSION=2.10.0

USER root

RUN mkdir -p /opt/agents /opt/jmx_exporter

ADD https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
    /opt/jmx_exporter/jmx_prometheus_javaagent.jar

ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar \
    /opt/agents/opentelemetry-javaagent.jar

# Cruise Control metrics reporter JAR is not on Maven Central — it ships with
# the linkedin/cruise-control tarball. Added in phase 6 alongside the
# cruise-control service image (copied from that build stage or fetched from
# the GitHub release tarball).

RUN chmod 0644 /opt/jmx_exporter/jmx_prometheus_javaagent.jar \
               /opt/agents/opentelemetry-javaagent.jar

COPY config/jmx/kafka-config.yml /opt/jmx_exporter/kafka-config.yml

USER appuser
