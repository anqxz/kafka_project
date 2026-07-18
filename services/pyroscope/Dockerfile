# Pyroscope multi-stage rebuild onto a patched alpine.
# 04-SECURITY-GUARDRAILS §2 phase 6.
ARG BASE_IMAGE=grafana/pyroscope
ARG BASE_TAG=1.7.1
ARG RUNTIME_TAG=3.20

FROM ${BASE_IMAGE}:${BASE_TAG} AS vendor

FROM alpine:${RUNTIME_TAG}
RUN apk --no-cache upgrade \
 && apk --no-cache add ca-certificates tzdata \
 && mkdir -p /etc/pyroscope /data \
 && chown -R nobody:nobody /etc/pyroscope /data

COPY --from=vendor /usr/bin/pyroscope /usr/bin/pyroscope

COPY config/pyroscope.yaml /etc/pyroscope/config.yaml

USER nobody
EXPOSE 4040
VOLUME ["/data"]
WORKDIR /data
ENTRYPOINT ["/usr/bin/pyroscope"]
CMD ["--config.file=/etc/pyroscope/config.yaml"]
