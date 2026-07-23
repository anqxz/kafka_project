# Kafka broker image with JMX exporter, OpenTelemetry javaagent, and
# Cruise Control metrics reporter baked in. Config lives under config/.
#
# CC reporter is not on Maven Central, so we build only the
# :cruise-control-metrics-reporter subproject from the tagged linkedin/
# cruise-control release inside an isolated builder stage. Broker runtime
# stage COPYs the resulting fat JAR into the Kafka classpath.

ARG BASE_IMAGE=confluentinc/cp-kafka
ARG BASE_TAG=7.9.6
ARG GRADLE_TAG=8-jdk17
ARG CC_VERSION=2.5.146

FROM gradle:${GRADLE_TAG} AS cc-reporter
ARG CC_VERSION
WORKDIR /src
ADD https://github.com/linkedin/cruise-control/archive/refs/tags/${CC_VERSION}.tar.gz /tmp/cc.tgz
RUN tar -xzf /tmp/cc.tgz --strip-components=1 -C /src \
 && apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/* \
 && git init -q -b main && git add -A \
    && git -c user.email=b@b -c user.name=b commit -q -m init \
    && git tag ${CC_VERSION} \
 && ./gradlew -x test :cruise-control-metrics-reporter:jar

FROM ${BASE_IMAGE}:${BASE_TAG}

ARG JMX_EXPORTER_VERSION=1.6.0
ARG OTEL_AGENT_VERSION=2.30.0
ARG PYROSCOPE_AGENT_VERSION=2.8.0

USER root

# Golden-base rebuild — apply every vendor OS patch on top of the pinned
# Confluent tag so Trivy CRITICAL/HIGH findings only come from CVEs
# nobody upstream has fixed. Runs once per image build, not per boot.
# Confluent's cp-* images sit on UBI8, so microdnf is the package tool.
# 04-SECURITY-GUARDRAILS §2 phase 6.
RUN microdnf update -y \
 && microdnf clean all

RUN mkdir -p /opt/agents /opt/jmx_exporter

ADD https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${JMX_EXPORTER_VERSION}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar \
    /opt/jmx_exporter/jmx_prometheus_javaagent.jar

ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar \
    /opt/agents/opentelemetry-javaagent.jar

ADD https://github.com/grafana/pyroscope-java/releases/download/v${PYROSCOPE_AGENT_VERSION}/pyroscope.jar \
    /opt/agents/pyroscope.jar

COPY --from=cc-reporter /src/cruise-control-metrics-reporter/build/libs/cruise-control-metrics-reporter-*.jar \
     /usr/share/java/kafka/cruise-control-metrics-reporter.jar
RUN chmod 0644 /opt/jmx_exporter/jmx_prometheus_javaagent.jar \
               /opt/agents/opentelemetry-javaagent.jar \
               /opt/agents/pyroscope.jar \
               /usr/share/java/kafka/cruise-control-metrics-reporter.jar

COPY config/jmx/kafka-config.yml /opt/jmx_exporter/kafka-config.yml

# cp-kafka's `ensure` step runs kafka-storage in a short-lived JVM that
# loads javaagents from KAFKA_OPTS — the JMX exporter binds :7071, exits,
# and TIME_WAIT keeps the port unusable long enough to race the real
# `launch` JVM into "Address already in use". Zero out KAFKA_OPTS for the
# ensure phase only; launch re-reads it fresh from container env.
RUN sed -i '2i export KAFKA_OPTS=""' /etc/confluent/docker/ensure

COPY --chmod=0755 entrypoint-ssl.sh /usr/local/bin/entrypoint-ssl.sh

USER appuser

ENTRYPOINT ["/usr/local/bin/entrypoint-ssl.sh"]

