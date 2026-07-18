# Cruise Control — LinkedIn's Kafka rebalancer / self-healer. Not on Docker
# Hub with an official image; built from the tagged GitHub release. Broker
# image will pick up the metrics reporter JAR extracted from libs/ in
# phase 7.
ARG GRADLE_TAG=8-jdk11
ARG RUNTIME_TAG=11-jre

FROM gradle:${GRADLE_TAG} AS builder
ARG CC_VERSION=2.5.138
WORKDIR /src
ADD https://github.com/linkedin/cruise-control/archive/refs/tags/${CC_VERSION}.tar.gz /tmp/cc.tgz
RUN tar -xzf /tmp/cc.tgz --strip-components=1 -C /src \
 && apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/* \
 && git init -q -b main && git add -A && git -c user.email=b@b -c user.name=b commit -q -m init \
 && git tag ${CC_VERSION} \
 && ./gradlew -x test :cruise-control:jar :cruise-control:copyDependantLibs

FROM eclipse-temurin:${RUNTIME_TAG}
LABEL org.opencontainers.image.source="https://github.com/linkedin/cruise-control"

# Golden-base rebuild — 04-SECURITY-GUARDRAILS §2 phase 6.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/cruise-control
COPY --from=builder /src/cruise-control/build/libs/          /opt/cruise-control/libs/
COPY --from=builder /src/cruise-control/build/dependant-libs/ /opt/cruise-control/libs/
COPY --from=builder /src/config/                              /opt/cruise-control/config-default/
COPY config/cruisecontrol.properties                          /opt/cruise-control/config/cruisecontrol.properties
COPY --chmod=0755 entrypoint-auth.sh                          /usr/local/bin/entrypoint-auth.sh
EXPOSE 9090
ENTRYPOINT ["/usr/local/bin/entrypoint-auth.sh"]
