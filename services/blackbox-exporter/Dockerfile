# Blackbox exporter multi-stage rebuild onto a patched alpine.
# 04-SECURITY-GUARDRAILS §2 phase 6.
ARG BASE_IMAGE=prom/blackbox-exporter
ARG BASE_TAG=v0.28.0
ARG RUNTIME_TAG=3.21

FROM ${BASE_IMAGE}:${BASE_TAG} AS vendor

FROM alpine:${RUNTIME_TAG}
RUN apk --no-cache upgrade \
 && apk --no-cache add ca-certificates tzdata \
 && mkdir -p /etc/blackbox_exporter \
 && chown -R nobody:nobody /etc/blackbox_exporter

COPY --from=vendor /bin/blackbox_exporter /bin/blackbox_exporter

COPY config/blackbox.yml /etc/blackbox_exporter/blackbox.yml

USER nobody
EXPOSE 9115
ENTRYPOINT ["/bin/blackbox_exporter"]
CMD ["--config.file=/etc/blackbox_exporter/blackbox.yml"]
