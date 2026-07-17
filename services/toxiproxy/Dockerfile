# Toxiproxy — fault injection between Connect and LocalStack (and any other
# tenant flows). API on :8474, proxied endpoints on their configured ports.
# Toxics are loaded at startup from toxics.json via -config.
ARG BASE_IMAGE=ghcr.io/shopify/toxiproxy
ARG BASE_TAG=2.9.0
FROM ${BASE_IMAGE}:${BASE_TAG}

COPY config/toxics.json /etc/toxiproxy/toxics.json

ENTRYPOINT ["/toxiproxy"]
CMD ["-host=0.0.0.0", "-config=/etc/toxiproxy/toxics.json"]
