#!/usr/bin/env bash
set -euo pipefail

# Bring up Fabric test-network and channel only (no chaincode deployment)
# Usage:
#   chmod +x src/scripts/deploy_testnetwork_blockchain.sh
#   src/scripts/deploy_testnetwork_blockchain.sh

FABRIC_SAMPLES_DIR="${FABRIC_SAMPLES_DIR:-$HOME/fabric-samples}"
TEST_NETWORK_DIR="$FABRIC_SAMPLES_DIR/test-network"
CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"
CLEAN_START="${CLEAN_START:-false}"

bootstrap_fabric_samples() {
  if [[ ! -x "$TEST_NETWORK_DIR/network.sh" ]]; then
    echo "[bootstrap] Official test-network script not found, installing/updating fabric-samples"
    if [[ -d "$FABRIC_SAMPLES_DIR" && ! -d "$FABRIC_SAMPLES_DIR/.git" ]]; then
      BACKUP_DIR="${FABRIC_SAMPLES_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
      echo "[bootstrap] Existing $FABRIC_SAMPLES_DIR is not a git clone. Moving it to $BACKUP_DIR"
      mv "$FABRIC_SAMPLES_DIR" "$BACKUP_DIR"
    fi

    pushd "$HOME" >/dev/null
    curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
    chmod +x install-fabric.sh
    ./install-fabric.sh docker samples binary
    popd >/dev/null
  fi

  if [[ ! -x "$TEST_NETWORK_DIR/network.sh" ]]; then
    echo "Unable to find $TEST_NETWORK_DIR/network.sh after installation attempt"
    exit 1
  fi
}

info() { echo "[$(date +%H:%M:%S)] $*"; }

bootstrap_fabric_samples

export PATH="$FABRIC_SAMPLES_DIR/bin:$PATH"
export FABRIC_CFG_PATH="$FABRIC_SAMPLES_DIR/config"

pushd "$TEST_NETWORK_DIR" >/dev/null

if [[ "$CLEAN_START" == "true" ]]; then
  info "Stopping existing network (clean start requested)"
  ./network.sh down || true
fi

if docker ps --format '{{.Names}}' | grep -q '^peer0.org1.example.com$'; then
  info "Fabric test-network appears to be running. Skipping blockchain redeploy."
else
  info "Starting Fabric test-network and creating channel: $CHANNEL_NAME"
  set +e
  UP_OUTPUT=$(./network.sh up createChannel -c "$CHANNEL_NAME" 2>&1)
  UP_RC=$?
  set -e

  if [[ $UP_RC -ne 0 ]]; then
    echo "$UP_OUTPUT"
    if echo "$UP_OUTPUT" | grep -qiE "channel already exists|ledger \[$CHANNEL_NAME\] already exists"; then
      info "Channel $CHANNEL_NAME already exists. Treating as success."
    else
      echo "Failed to start Fabric test-network"
      exit $UP_RC
    fi
  else
    echo "$UP_OUTPUT"
  fi
fi

info "Blockchain deployment completed"
info "Next: run src/scripts/deploy_testnetwork_ccaas_mwc.sh for chaincode deployment"

popd >/dev/null
