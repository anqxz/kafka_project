ARG BASE_IMAGE=grafana/grafana
ARG BASE_TAG=11.2.0
FROM ${BASE_IMAGE}:${BASE_TAG}

USER root
# Golden-base rebuild (Alpine apk) — 04-SECURITY-GUARDRAILS §2 phase 6.
RUN apk --no-cache upgrade
USER grafana

COPY provisioning/ /etc/grafana/provisioning/
