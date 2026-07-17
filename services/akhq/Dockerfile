# AKHQ bakes application.yml so the compose file no longer needs a
# multiline AKHQ_CONFIGURATION env blob. Path /app/application.yml is the
# default location the upstream entrypoint looks for.
ARG BASE_IMAGE=tchiotludo/akhq
ARG BASE_TAG=0.25.1
FROM ${BASE_IMAGE}:${BASE_TAG}

COPY config/application.yml /app/application.yml
