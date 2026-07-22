FROM smallstep/step-ca:0.26.1
USER root
RUN apk add --no-cache openssl openjdk11-jre-headless bash
COPY init/ /init/
RUN chmod +x /init/*.sh
# entrypoint is set per compose service
