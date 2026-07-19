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

# Render the analyzer's SASL/SCRAM credentials into a working copy of
# cruisecontrol.properties. KafkaCruiseControlMain accepts a single
# config-file positional arg; a second arg is parsed as port. So we
# concatenate rather than pass two files.
WORK_CONFIG=/opt/cruise-control/config/cruisecontrol.runtime.properties
cp /opt/cruise-control/config/cruisecontrol.properties "$WORK_CONFIG"
if [ -n "${SCRAM_CC_PASSWORD:-}" ]; then
  {
    echo
    echo "# rendered by entrypoint-auth.sh from SCRAM_CC_PASSWORD"
    echo "sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"cruise-control\" password=\"${SCRAM_CC_PASSWORD}\";"
  } >> "$WORK_CONFIG"
fi
chmod 0600 "$WORK_CONFIG"

exec java -cp "libs/*" \
  com.linkedin.kafka.cruisecontrol.KafkaCruiseControlMain \
  "$WORK_CONFIG"
