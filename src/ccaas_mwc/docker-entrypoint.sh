#!/usr/bin/env bash
set -euo pipefail

export CORE_PEER_TLS_ENABLED=${CORE_PEER_TLS_ENABLED:-"false"}
export CHAINCODE_SERVER_PORT=${CHAINCODE_SERVER_PORT:-9999}
export CHAINCODE_SERVER_ADDRESS=${CHAINCODE_SERVER_ADDRESS:-"0.0.0.0:${CHAINCODE_SERVER_PORT}"}

if [[ "${CORE_PEER_TLS_ENABLED}" != "true" && "${CORE_PEER_TLS_ENABLED}" != "false" ]]; then
  echo "CORE_PEER_TLS_ENABLED must be 'true' or 'false'."
  exit 1
fi

exec /chaincode/chaincode
