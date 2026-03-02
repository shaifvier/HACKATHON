#!/usr/bin/env bash
#
# SPDX-License-Identifier: Apache-2.0
#
set -euo pipefail

# Ensure CORE_PEER_TLS_ENABLED and DEBUG are set
export CORE_PEER_TLS_ENABLED=${CORE_PEER_TLS_ENABLED:-"false"}
export CHAINCODE_SERVER_PORT=${CHAINCODE_SERVER_PORT:-9999}
export DEBUG=${DEBUG:-"false"}

if [[ "$CORE_PEER_TLS_ENABLED" != "true" && "$CORE_PEER_TLS_ENABLED" != "false" ]]; then
    echo "❌ ERROR: CORE_PEER_TLS_ENABLED must be 'true' or 'false'. Current value: $CORE_PEER_TLS_ENABLED"
    exit 1
fi

if [ "${DEBUG,,}" = "true" ]; then
   echo "🛠️ Debug mode enabled, starting chaincode with Delve..."
   exec dlv --listen=:40000 --headless=true --api-version=2 exec /chaincode/chaincode -- -peer.address=0.0.0.0:${CHAINCODE_SERVER_PORT}
else
   echo "🚀 Starting chaincode..."
   exec /chaincode/chaincode
fi
