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
COPY config/jaas.conf             /etc/schema-registry/jaas.conf
COPY --chmod=0755 entrypoint-auth.sh /usr/local/bin/entrypoint-auth.sh

# AWS msk-config-providers so kafkastore properties can resolve
# ${secretsmanager:…} placeholders. 04-SECURITY-GUARDRAILS §2 phase 5.
ARG MSK_CONFIG_PROVIDERS_VERSION=0.1.2
ADD https://github.com/aws-samples/msk-config-providers/releases/download/v${MSK_CONFIG_PROVIDERS_VERSION}/msk-config-providers-${MSK_CONFIG_PROVIDERS_VERSION}-with-dependencies.zip \
    /tmp/msk-config-providers.zip
RUN mkdir -p /usr/share/java/msk-config-providers \
 && (unzip -q /tmp/msk-config-providers.zip -d /usr/share/java/msk-config-providers \
      || (apt-get update && apt-get install -y --no-install-recommends unzip \
          && unzip -q /tmp/msk-config-providers.zip -d /usr/share/java/msk-config-providers \
          && rm -rf /var/lib/apt/lists/*)) \
 && rm /tmp/msk-config-providers.zip

USER appuser

ENTRYPOINT ["/usr/local/bin/entrypoint-auth.sh"]
