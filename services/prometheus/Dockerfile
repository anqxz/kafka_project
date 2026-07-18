# Prometheus multi-stage rebuild: copy the static Go binaries + license
# out of the vendor image and drop them onto a freshly-patched
# alpine:3.20. Skips the vendor's own base entirely — Trivy findings
# against Prometheus now come from the alpine root filesystem, which
# we patch on every rebuild.
# 04-SECURITY-GUARDRAILS §2 phase 6.
ARG BASE_IMAGE=prom/prometheus
ARG BASE_TAG=v3.13.1
ARG RUNTIME_TAG=3.21

FROM ${BASE_IMAGE}:${BASE_TAG} AS vendor

FROM alpine:${RUNTIME_TAG}
RUN apk --no-cache upgrade \
 && apk --no-cache add ca-certificates tzdata \
 && mkdir -p /etc/prometheus /prometheus \
 && chown -R nobody:nobody /etc/prometheus /prometheus

COPY --from=vendor /bin/prometheus              /bin/prometheus
COPY --from=vendor /bin/promtool                /bin/promtool

COPY config/prometheus.yml /etc/prometheus/prometheus.yml
COPY config/rules/         /etc/prometheus/rules/

USER nobody
EXPOSE 9090
VOLUME ["/prometheus"]
WORKDIR /prometheus
ENTRYPOINT ["/bin/prometheus"]
CMD ["--config.file=/etc/prometheus/prometheus.yml", \
     "--storage.tsdb.path=/prometheus"]
