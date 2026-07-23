# Kroxylicious — Kafka protocol proxy. Filter chain (RecordEncryption via
# LocalStack KMS) is defined in config/proxy.yaml.
ARG BASE_IMAGE=quay.io/kroxylicious/kroxylicious
ARG BASE_TAG=0.11.0
FROM ${BASE_IMAGE}:${BASE_TAG}

COPY config/proxy.yaml /opt/kroxylicious/config/proxy.yaml

CMD ["-c", "/opt/kroxylicious/config/proxy.yaml"]
