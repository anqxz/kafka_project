#!/usr/bin/env bash
# Render Cruise Control's basic-auth password file from env at startup.
# Format: `username: password,ROLE`.
set -euo pipefail

if [ -n "${CRUISE_CONTROL_ADMIN_USER:-}" ] && [ -n "${CRUISE_CONTROL_ADMIN_PASSWORD:-}" ]; then
  {
    echo "${CRUISE_CONTROL_ADMIN_USER}: ${CRUISE_CONTROL_ADMIN_PASSWORD},ADMIN"
  } > /opt/cruise-control/config/auth.properties
  chmod 0600 /opt/cruise-control/config/auth.properties
fi

exec java -cp "libs/*" \
  com.linkedin.kafka.cruisecontrol.KafkaCruiseControlMain \
  /opt/cruise-control/config/cruisecontrol.properties
