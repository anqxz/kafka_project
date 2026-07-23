# LocalStack has no long-lived config file — initialization happens via
# scripts under /etc/localstack/init/ready.d/ executed once the runtime is
# ready. Bake the init/ tree so the container is self-provisioning.
ARG BASE_IMAGE=localstack/localstack
ARG BASE_TAG=4.14
FROM ${BASE_IMAGE}:${BASE_TAG}

COPY --chmod=0755 init/ /etc/localstack/init/ready.d/
