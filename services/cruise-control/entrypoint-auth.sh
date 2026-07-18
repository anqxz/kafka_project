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

# Render the analyzer's SASL/SCRAM credentials into a private properties
# file, then hand it to CC's main class alongside the checked-in config.
# CC merges positional --config-file arguments left-to-right, so later
# entries override earlier ones.
if [ -n "${SCRAM_CC_PASSWORD:-}" ]; then
  umask 0177
  cat > /opt/cruise-control/config/sasl.properties <<PROPS
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="cruise-control" password="${SCRAM_CC_PASSWORD}";
PROPS
fi

exec java -cp "libs/*" \
  com.linkedin.kafka.cruisecontrol.KafkaCruiseControlMain \
  config/cruisecontrol.properties \
  config/sasl.properties
