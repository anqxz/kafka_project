# Kafka Connect image with S3 sink connector (baked via confluent-hub) and
# OpenTelemetry javaagent for trace propagation across Connect tasks.
ARG BASE_IMAGE=confluentinc/cp-kafka-connect
ARG BASE_TAG=7.7.1
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG OTEL_AGENT_VERSION=2.10.0
ARG JMX_EXPORTER_VERSION=1.0.1
ARG S3_CONNECTOR_VERSION=10.5.13

USER root

RUN mkdir -p /opt/agents /opt/jmx_exporter

ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar \
    /opt/agents/opentelemetry-javaagent.jar

ADD https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
    /opt/jmx_exporter/jmx_prometheus_javaagent.jar

RUN chmod 0644 /opt/agents/opentelemetry-javaagent.jar \
               /opt/jmx_exporter/jmx_prometheus_javaagent.jar

# Bake S3 sink connector so runtime plugin download is not required.
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-s3:${S3_CONNECTOR_VERSION}

COPY config/jmx/kafka-config.yml /opt/jmx_exporter/kafka-config.yml

USER appuser
