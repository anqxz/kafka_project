ARG BASE_IMAGE=redpandadata/kminion
ARG BASE_TAG=v2.2.11
FROM ${BASE_IMAGE}:${BASE_TAG}

USER root
# Golden-base rebuild (Alpine apk) — 04-SECURITY-GUARDRAILS §2 phase 6.
RUN apk --no-cache upgrade

COPY config/kminion.yaml /etc/kminion/config.yaml
