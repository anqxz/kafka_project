# Alertmanager multi-stage rebuild onto a patched alpine.
# 04-SECURITY-GUARDRAILS §2 phase 6.
ARG BASE_IMAGE=prom/alertmanager
ARG BASE_TAG=v0.27.0
ARG RUNTIME_TAG=3.20

FROM ${BASE_IMAGE}:${BASE_TAG} AS vendor

FROM alpine:${RUNTIME_TAG}
RUN apk --no-cache upgrade \
 && apk --no-cache add ca-certificates tzdata \
 && mkdir -p /etc/alertmanager /alertmanager \
 && chown -R nobody:nobody /etc/alertmanager /alertmanager

COPY --from=vendor /bin/alertmanager /bin/alertmanager
COPY --from=vendor /bin/amtool       /bin/amtool
COPY --from=vendor /LICENSE          /LICENSE
COPY --from=vendor /NOTICE           /NOTICE

COPY config/alertmanager.yml /etc/alertmanager/alertmanager.yml

USER nobody
EXPOSE 9093
VOLUME ["/alertmanager"]
WORKDIR /alertmanager
ENTRYPOINT ["/bin/alertmanager"]
CMD ["--config.file=/etc/alertmanager/alertmanager.yml", \
     "--storage.path=/alertmanager"]
