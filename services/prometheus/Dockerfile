ARG BASE_IMAGE=prom/prometheus
ARG BASE_TAG=v2.55.0
FROM ${BASE_IMAGE}:${BASE_TAG}

COPY config/prometheus.yml /etc/prometheus/prometheus.yml
COPY config/rules/         /etc/prometheus/rules/
