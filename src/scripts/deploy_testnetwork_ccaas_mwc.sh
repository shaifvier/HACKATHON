#!/usr/bin/env bash
set -euo pipefail

# CCaaS chaincode deployment only (no blockchain redeploy)
# Usage:
#   chmod +x src/scripts/deploy_testnetwork_ccaas_mwc.sh
#   src/scripts/deploy_testnetwork_ccaas_mwc.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FABRIC_SAMPLES_DIR="${FABRIC_SAMPLES_DIR:-$HOME/fabric-samples}"
TEST_NETWORK_DIR="$FABRIC_SAMPLES_DIR/test-network"
CC_SRC_DIR="${CC_SRC_DIR:-$REPO_ROOT/src/ccaas_mwc}"

CHANNEL_NAME="${CHANNEL_NAME:-mychannel}"
CC_NAME="${CC_NAME:-pqc_mwc}"
CC_LABEL="${CC_LABEL:-${CC_NAME}_1}"
CC_VERSION="${CC_VERSION:-1.0}"
CC_SEQUENCE="${CC_SEQUENCE:-}"
CC_PORT="${CC_PORT:-9999}"
CC_CONTAINER_NAME="${CC_CONTAINER_NAME:-pqc-mwc-ccaas}"
FORCE_LIFECYCLE="${FORCE_LIFECYCLE:-false}"

export PATH="$FABRIC_SAMPLES_DIR/bin:$PATH"
export FABRIC_CFG_PATH="$FABRIC_SAMPLES_DIR/config"

if [[ ! -d "$TEST_NETWORK_DIR" ]]; then
  echo "fabric-samples not found at $FABRIC_SAMPLES_DIR"
  echo "Install it first: curl -sSL https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh | bash -s"
  exit 1
fi

if [[ ! -x "$TEST_NETWORK_DIR/network.sh" ]]; then
  echo "Unable to find $TEST_NETWORK_DIR/network.sh"
  exit 1
fi

if [[ ! -f "$CC_SRC_DIR/main.go" ]]; then
  echo "Chaincode source not found at $CC_SRC_DIR"
  exit 1
fi

ORDERER_CA="$TEST_NETWORK_DIR/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"

PEER0_ORG1_CA="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
PEER0_ORG2_CA="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"

ORG1_ADMIN_MSP="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
ORG2_ADMIN_MSP="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp"

setGlobalsOrg1() {
  export CORE_PEER_LOCALMSPID="Org1MSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$PEER0_ORG1_CA"
  export CORE_PEER_MSPCONFIGPATH="$ORG1_ADMIN_MSP"
  export CORE_PEER_ADDRESS="localhost:7051"
  export CORE_PEER_TLS_ENABLED=true
}

setGlobalsOrg2() {
  export CORE_PEER_LOCALMSPID="Org2MSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="$PEER0_ORG2_CA"
  export CORE_PEER_MSPCONFIGPATH="$ORG2_ADMIN_MSP"
  export CORE_PEER_ADDRESS="localhost:9051"
  export CORE_PEER_TLS_ENABLED=true
}

info() { echo "[$(date +%H:%M:%S)] $*"; }

pushd "$TEST_NETWORK_DIR" >/dev/null

if ! docker ps --format '{{.Names}}' | grep -q '^peer0.org1.example.com$'; then
  echo "Fabric network is not running. Deploy blockchain first using src/scripts/deploy_testnetwork_blockchain.sh"
  exit 1
fi

PKG_DIR="$TEST_NETWORK_DIR/.ccaas/${CC_NAME}"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/src" "$PKG_DIR/pkg"

cat > "$PKG_DIR/src/connection.json" <<EOF
{
  "address": "${CC_CONTAINER_NAME}:${CC_PORT}",
  "dial_timeout": "10s",
  "tls_required": false
}
EOF

cat > "$PKG_DIR/pkg/metadata.json" <<EOF
{
  "type": "ccaas",
  "label": "${CC_LABEL}"
}
EOF

tar -C "$PKG_DIR/src" -czf "$PKG_DIR/pkg/code.tar.gz" connection.json
tar -C "$PKG_DIR/pkg" -czf "$PKG_DIR/${CC_NAME}.tgz" metadata.json code.tar.gz

PACKAGE_ID=$(peer lifecycle chaincode calculatepackageid "$PKG_DIR/${CC_NAME}.tgz")
info "Calculated PACKAGE_ID: $PACKAGE_ID"

CURRENT_SEQUENCE=""
if setGlobalsOrg1 && peer lifecycle chaincode querycommitted --channelID "$CHANNEL_NAME" --name "$CC_NAME" >/tmp/.cc_query 2>/dev/null; then
  CURRENT_SEQUENCE=$(sed -n 's/.*Sequence: \([0-9]\+\).*/\1/p' /tmp/.cc_query | head -n1)
fi
rm -f /tmp/.cc_query

RUN_LIFECYCLE=true
if [[ -n "$CURRENT_SEQUENCE" && "$FORCE_LIFECYCLE" != "true" ]]; then
  RUN_LIFECYCLE=false
  info "Chaincode definition already exists (sequence $CURRENT_SEQUENCE). Skipping lifecycle."
  info "Set FORCE_LIFECYCLE=true to run approve/commit upgrade."
fi

if [[ -z "$CURRENT_SEQUENCE" ]]; then
  EFFECTIVE_SEQUENCE="${CC_SEQUENCE:-1}"
else
  EFFECTIVE_SEQUENCE="${CC_SEQUENCE:-$((CURRENT_SEQUENCE + 1))}"
fi

if [[ "$RUN_LIFECYCLE" == "false" ]]; then
  setGlobalsOrg1
  APPROVED_DEF=$(peer lifecycle chaincode queryapproved \
    -C "$CHANNEL_NAME" \
    -n "$CC_NAME" \
    --sequence "$CURRENT_SEQUENCE" 2>/dev/null || true)

  APPROVED_PACKAGE_ID=$(echo "$APPROVED_DEF" | sed -n 's/.*package-id: \([^,]*\),.*/\1/p' | head -n1 | xargs)

  if [[ -z "$APPROVED_PACKAGE_ID" ]]; then
    echo "Unable to determine approved package-id for ${CC_NAME} (sequence ${CURRENT_SEQUENCE})."
    echo "Re-run with FORCE_LIFECYCLE=true to re-approve/commit and align the package ID."
    exit 1
  fi

  PACKAGE_ID="$APPROVED_PACKAGE_ID"
  info "Using approved PACKAGE_ID from committed definition: $PACKAGE_ID"
fi

if [[ "$RUN_LIFECYCLE" == "true" ]]; then
  setGlobalsOrg1
  info "Installing package on Org1"
  peer lifecycle chaincode install "$PKG_DIR/${CC_NAME}.tgz" || true

  setGlobalsOrg2
  info "Installing package on Org2"
  peer lifecycle chaincode install "$PKG_DIR/${CC_NAME}.tgz" || true

  setGlobalsOrg1
  info "Approving chaincode for Org1 (sequence $EFFECTIVE_SEQUENCE)"
  peer lifecycle chaincode approveformyorg \
    -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    --channelID "$CHANNEL_NAME" \
    --name "$CC_NAME" \
    --version "$CC_VERSION" \
    --package-id "$PACKAGE_ID" \
    --sequence "$EFFECTIVE_SEQUENCE"

  setGlobalsOrg2
  info "Approving chaincode for Org2 (sequence $EFFECTIVE_SEQUENCE)"
  peer lifecycle chaincode approveformyorg \
    -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    --channelID "$CHANNEL_NAME" \
    --name "$CC_NAME" \
    --version "$CC_VERSION" \
    --package-id "$PACKAGE_ID" \
    --sequence "$EFFECTIVE_SEQUENCE"

  setGlobalsOrg1
  info "Checking commit readiness"
  peer lifecycle chaincode checkcommitreadiness \
    --channelID "$CHANNEL_NAME" \
    --name "$CC_NAME" \
    --version "$CC_VERSION" \
    --sequence "$EFFECTIVE_SEQUENCE" \
    --output json

  info "Committing chaincode definition"
  peer lifecycle chaincode commit \
    -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    --channelID "$CHANNEL_NAME" \
    --name "$CC_NAME" \
    --version "$CC_VERSION" \
    --sequence "$EFFECTIVE_SEQUENCE" \
    --peerAddresses localhost:7051 --tlsRootCertFiles "$PEER0_ORG1_CA" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "$PEER0_ORG2_CA"
fi

FABRIC_NET=$(docker inspect peer0.org1.example.com --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
if [[ -z "$FABRIC_NET" ]]; then
  echo "Unable to detect Fabric Docker network"
  exit 1
fi

info "Building chaincode service image from $CC_SRC_DIR"
docker build -t "${CC_CONTAINER_NAME}:latest" "$CC_SRC_DIR"

info "Starting chaincode service container on network: $FABRIC_NET"
docker rm -f "$CC_CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$CC_CONTAINER_NAME" \
  --network "$FABRIC_NET" \
  -e CHAINCODE_SERVER_ADDRESS="0.0.0.0:${CC_PORT}" \
  -e CHAINCODE_ID="$PACKAGE_ID" \
  -e CORE_CHAINCODE_ID_NAME="$PACKAGE_ID" \
  -e CHAINCODE_TLS_DISABLED=true \
  "${CC_CONTAINER_NAME}:latest"

info "Deployment completed"
info "Container logs: docker logs -f $CC_CONTAINER_NAME"
info "Query example: ./network.sh cc query -org 1 -c $CHANNEL_NAME -ccn $CC_NAME -ccqc '{\"Args\":[\"GetReputation\",\"controllerA\"]}'"

popd >/dev/null
