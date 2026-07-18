# AKHQ bakes application.yml so the compose file no longer needs a
# multiline AKHQ_CONFIGURATION env blob. Path /app/application.yml is the
# default location the upstream entrypoint looks for.
ARG BASE_IMAGE=tchiotludo/akhq
ARG BASE_TAG=0.25.1
FROM ${BASE_IMAGE}:${BASE_TAG}

USER root
# Golden-base rebuild — probes for the pkg manager since tchiotludo/akhq
# has flipped between Debian and Alpine bases across tags.
# 04-SECURITY-GUARDRAILS §2 phase 6.
RUN if command -v apt-get >/dev/null 2>&1; then \
      apt-get update && apt-get upgrade -y && apt-get autoremove -y \
        && rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null 2>&1; then \
      apk --no-cache upgrade; \
    else \
      echo "unknown base — no package manager available" >&2; exit 1; \
    fi
USER akhq

COPY config/application.yml /app/application.yml
