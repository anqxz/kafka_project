# LocalStack has no long-lived config file — initialization happens via
# scripts under /etc/localstack/init/ready.d/ executed once the runtime is
# ready. Bake the init/ tree so the container is self-provisioning.
ARG BASE_IMAGE=localstack/localstack
ARG BASE_TAG=3.8
FROM ${BASE_IMAGE}:${BASE_TAG}

COPY init/ /etc/localstack/init/
