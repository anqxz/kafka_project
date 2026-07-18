# kminion multi-stage rebuild onto a patched alpine.
# 04-SECURITY-GUARDRAILS §2 phase 6.
ARG BASE_IMAGE=redpandadata/kminion
ARG BASE_TAG=v2.3.3
ARG RUNTIME_TAG=3.21

FROM ${BASE_IMAGE}:${BASE_TAG} AS vendor

FROM alpine:${RUNTIME_TAG}
RUN apk --no-cache upgrade \
 && apk --no-cache add ca-certificates tzdata \
 && mkdir -p /etc/kminion \
 && chown -R nobody:nobody /etc/kminion

COPY --from=vendor /app/kminion /app/kminion

COPY config/kminion.yaml /etc/kminion/config.yaml

USER nobody
EXPOSE 8080
WORKDIR /app
ENTRYPOINT ["/app/kminion"]
