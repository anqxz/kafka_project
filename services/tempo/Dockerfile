# Tempo multi-stage rebuild onto a patched alpine.
# 04-SECURITY-GUARDRAILS §2 phase 6.
ARG BASE_IMAGE=grafana/tempo
ARG BASE_TAG=3.0.2
ARG RUNTIME_TAG=3.21

FROM ${BASE_IMAGE}:${BASE_TAG} AS vendor

FROM alpine:${RUNTIME_TAG}
RUN apk --no-cache upgrade \
 && apk --no-cache add ca-certificates tzdata \
 && mkdir -p /etc/tempo /var/tempo \
 && chown -R nobody:nobody /etc/tempo /var/tempo

COPY --from=vendor /tempo /tempo

COPY config/tempo.yaml /etc/tempo/config.yaml

USER nobody
EXPOSE 3200
VOLUME ["/var/tempo"]
WORKDIR /var/tempo
ENTRYPOINT ["/tempo"]
CMD ["-config.file=/etc/tempo/config.yaml"]
