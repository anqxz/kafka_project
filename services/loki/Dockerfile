# Loki multi-stage rebuild onto a patched alpine.
# 04-SECURITY-GUARDRAILS §2 phase 6.
ARG BASE_IMAGE=grafana/loki
ARG BASE_TAG=3.2.0
ARG RUNTIME_TAG=3.20

FROM ${BASE_IMAGE}:${BASE_TAG} AS vendor

FROM alpine:${RUNTIME_TAG}
RUN apk --no-cache upgrade \
 && apk --no-cache add ca-certificates tzdata \
 && mkdir -p /etc/loki /loki \
 && chown -R nobody:nobody /etc/loki /loki

COPY --from=vendor /usr/bin/loki /usr/bin/loki

COPY config/loki.yaml /etc/loki/config.yaml

USER nobody
EXPOSE 3100
VOLUME ["/loki"]
WORKDIR /loki
ENTRYPOINT ["/usr/bin/loki"]
CMD ["-config.file=/etc/loki/config.yaml"]
