ARG BASE_IMAGE=binwiederhier/ntfy
ARG BASE_TAG=v2.11.0
FROM ${BASE_IMAGE}:${BASE_TAG}

USER root
# Golden-base rebuild (Alpine apk) — 04-SECURITY-GUARDRAILS §2 phase 6.
RUN apk --no-cache upgrade

COPY config/ntfy.yml /etc/ntfy/ntfy.yml
