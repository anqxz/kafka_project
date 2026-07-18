# ntfy multi-stage rebuild onto a patched alpine.
# 04-SECURITY-GUARDRAILS §2 phase 6.
ARG BASE_IMAGE=binwiederhier/ntfy
ARG BASE_TAG=v2.26.0
ARG RUNTIME_TAG=3.21

FROM ${BASE_IMAGE}:${BASE_TAG} AS vendor

FROM alpine:${RUNTIME_TAG}
RUN apk --no-cache upgrade \
 && apk --no-cache add ca-certificates tzdata \
 && mkdir -p /etc/ntfy /var/lib/ntfy \
 && chown -R nobody:nobody /etc/ntfy /var/lib/ntfy

COPY --from=vendor /usr/bin/ntfy /usr/bin/ntfy

COPY config/ntfy.yml /etc/ntfy/ntfy.yml

USER nobody
EXPOSE 80
VOLUME ["/var/lib/ntfy"]
ENTRYPOINT ["/usr/bin/ntfy"]
CMD ["serve", "--config", "/etc/ntfy/ntfy.yml"]
