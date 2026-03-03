#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Deploying Fabric network (adrenaline) + pqc_chaincode (CCaaS)…"

BASE="$HOME/fabric-samples/test-network"
BIN="$HOME/fabric-samples/bin"
CFG="$HOME/fabric-samples/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPOSE_FILE="$BASE/compose/compose_pqc.yaml"
if [ ! -f "$COMPOSE_FILE" ] && [ -f "$SCRIPT_DIR/compose_pqc.yaml" ]; then
  COMPOSE_FILE="$SCRIPT_DIR/compose_pqc.yaml"
fi
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "❌ Compose file not found. Checked:"
  echo "   - $BASE/compose/compose_pqc.yaml"
  echo "   - $SCRIPT_DIR/compose_pqc.yaml"
  exit 1
fi
NETWORK_NAME="fabric_adrenaline"

CHANNEL_NAME="channel1"
PROFILE_NAME="ChannelUsingRaft"
CC_NAME="pqc_chaincode"
CC_VERSION="1.0"
CC_SERVER_PORT=9999

ORG1_MSP="Org1MSP"
ORG1_ADMIN_MSP="$BASE/organizations/peerOrganizations/org1.adrenaline.com/users/Admin@org1.adrenaline.com/msp"

PEER0_TLS_CA="$BASE/organizations/peerOrganizations/org1.adrenaline.com/peers/peer0.org1.adrenaline.com/tls/ca.crt"

ORDERER_CA="$BASE/organizations/ordererOrganizations/adrenaline.com/orderers/orderer.adrenaline.com/tls/ca.crt"
ORD_ADMIN_CERT="$BASE/organizations/ordererOrganizations/adrenaline.com/orderers/orderer.adrenaline.com/tls/server.crt"
ORD_ADMIN_KEY="$BASE/organizations/ordererOrganizations/adrenaline.com/orderers/orderer.adrenaline.com/tls/server.key"

ORDERER1_ADMIN_ADDR="localhost:7053"
ORDERER2_ADMIN_ADDR="localhost:8053"
ORDERER3_ADMIN_ADDR="localhost:9053"
ORDERER1_ADDR="localhost:7050"

PEER0_ADDR="localhost:7051"
PEER1_ADDR="localhost:8051"
PEER2_ADDR="localhost:9051"

export PATH="$BIN:$PATH"
export FABRIC_CFG_PATH="$CFG"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DOCKER_CMD=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
  DOCKER_CMD=(sudo docker)
else
  echo "❌ Docker is not available (or daemon is not running)."
  echo "   Try: sudo systemctl start docker"
  exit 1
fi

if command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
elif "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1; then
  COMPOSE_CMD=("${DOCKER_CMD[@]}" compose)
else
  echo "❌ Docker Compose is not installed."
  exit 1
fi

echo "🚀 Starting Hyperledger Fabric deployment for Adrenaline test-bed..."

# Ensure binaries exist
if ! command -v cryptogen >/dev/null || ! command -v configtxgen >/dev/null; then
  echo "⬇️  Installing Fabric samples/binaries..."
  cd "$HOME"
  curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
  chmod +x install-fabric.sh
  bash install-fabric.sh
  export PATH="$HOME/fabric-samples/bin:$PATH"
fi

cd "$BASE"

# ── Clean artifacts
mkdir -p channel-artifacts
rm -f channel-artifacts/"$CHANNEL_NAME".block \
      channel-artifacts/config_block.pb \
      channel-artifacts/config_block.json \
      channel-artifacts/config.json \
      channel-artifacts/modified_config.json \
      channel-artifacts/config.pb \
      channel-artifacts/modified_config.pb \
      channel-artifacts/config_update.pb \
      channel-artifacts/config_update.json \
      channel-artifacts/config_update_in_envelope.json

# ── Generate crypto BEFORE bringing containers up
if [ -d organizations ]; then
  echo "🧹 Removing existing ./organizations to regenerate crypto…"
  rm -rf organizations
fi

echo "🔐 Generating crypto with cryptogen…"
cat > crypto-config.yaml <<'EOF'
OrdererOrgs:
  - Name: Orderer
    Domain: adrenaline.com
    EnableNodeOUs: true
    Specs:
      - Hostname: orderer
        SANS: [ "localhost" ]
      - Hostname: orderer2
        SANS: [ "localhost" ]
      - Hostname: orderer3
        SANS: [ "localhost" ]

PeerOrgs:
  - Name: Org1
    Domain: org1.adrenaline.com
    EnableNodeOUs: true
    Template:
      Count: 3
      SANS: [ "localhost" ]
    Users:
      Count: 3    # Admin + User1..User3
EOF

cryptogen generate --config=crypto-config.yaml --output=organizations
echo "✅ Crypto generated in $BASE/organizations"

echo "🧾 Generating configtx/configtx.yaml for adrenaline.com…"
mkdir -p configtx
cat > configtx/configtx.yaml <<'EOF'
Organizations:
  - &OrdererOrg
    Name: OrdererMSP
    ID: OrdererMSP
    MSPDir: organizations/ordererOrganizations/adrenaline.com/msp
    Policies:
      Readers:
        Type: Signature
        Rule: "OR('OrdererMSP.member')"
      Writers:
        Type: Signature
        Rule: "OR('OrdererMSP.member')"
      Admins:
        Type: Signature
        Rule: "OR('OrdererMSP.admin')"

  - &Org1
    Name: Org1MSP
    ID: Org1MSP
    MSPDir: organizations/peerOrganizations/org1.adrenaline.com/msp
    Policies:
      Readers:
        Type: Signature
        Rule: "OR('Org1MSP.admin', 'Org1MSP.peer', 'Org1MSP.client')"
      Writers:
        Type: Signature
        Rule: "OR('Org1MSP.admin', 'Org1MSP.client')"
      Admins:
        Type: Signature
        Rule: "OR('Org1MSP.admin')"
      Endorsement:
        Type: Signature
        Rule: "OR('Org1MSP.peer')"
    AnchorPeers:
      - Host: peer0.org1.adrenaline.com
        Port: 7051

Capabilities:
  Channel: &ChannelCapabilities
    V2_0: true
  Orderer: &OrdererCapabilities
    V2_0: true
  Application: &ApplicationCapabilities
    V2_5: true

Application: &ApplicationDefaults
  Policies:
    Readers:
      Type: ImplicitMeta
      Rule: "ANY Readers"
    Writers:
      Type: ImplicitMeta
      Rule: "ANY Writers"
    Admins:
      Type: ImplicitMeta
      Rule: "MAJORITY Admins"
    LifecycleEndorsement:
      Type: ImplicitMeta
      Rule: "MAJORITY Endorsement"
    Endorsement:
      Type: ImplicitMeta
      Rule: "MAJORITY Endorsement"
  Capabilities:
    <<: *ApplicationCapabilities

Orderer: &OrdererDefaults
  OrdererType: etcdraft
  Addresses:
    - orderer.adrenaline.com:7050
    - orderer2.adrenaline.com:8050
    - orderer3.adrenaline.com:9050
  EtcdRaft:
    Consenters:
      - Host: orderer.adrenaline.com
        Port: 7050
        ClientTLSCert: organizations/ordererOrganizations/adrenaline.com/orderers/orderer.adrenaline.com/tls/server.crt
        ServerTLSCert: organizations/ordererOrganizations/adrenaline.com/orderers/orderer.adrenaline.com/tls/server.crt
      - Host: orderer2.adrenaline.com
        Port: 8050
        ClientTLSCert: organizations/ordererOrganizations/adrenaline.com/orderers/orderer2.adrenaline.com/tls/server.crt
        ServerTLSCert: organizations/ordererOrganizations/adrenaline.com/orderers/orderer2.adrenaline.com/tls/server.crt
      - Host: orderer3.adrenaline.com
        Port: 9050
        ClientTLSCert: organizations/ordererOrganizations/adrenaline.com/orderers/orderer3.adrenaline.com/tls/server.crt
        ServerTLSCert: organizations/ordererOrganizations/adrenaline.com/orderers/orderer3.adrenaline.com/tls/server.crt
  BatchTimeout: 2s
  BatchSize:
    MaxMessageCount: 10
    AbsoluteMaxBytes: 99 MB
    PreferredMaxBytes: 512 KB
  Policies:
    Readers:
      Type: ImplicitMeta
      Rule: "ANY Readers"
    Writers:
      Type: ImplicitMeta
      Rule: "ANY Writers"
    Admins:
      Type: ImplicitMeta
      Rule: "MAJORITY Admins"
    BlockValidation:
      Type: ImplicitMeta
      Rule: "ANY Writers"
  Organizations:
  Capabilities:
    <<: *OrdererCapabilities

Channel: &ChannelDefaults
  Policies:
    Readers:
      Type: ImplicitMeta
      Rule: "ANY Readers"
    Writers:
      Type: ImplicitMeta
      Rule: "ANY Writers"
    Admins:
      Type: ImplicitMeta
      Rule: "MAJORITY Admins"
  Capabilities:
    <<: *ChannelCapabilities

Profiles:
  ChannelUsingRaft:
    <<: *ChannelDefaults
    Consortium: SampleConsortium
    Orderer:
      <<: *OrdererDefaults
      Organizations:
        - *OrdererOrg
    Application:
      <<: *ApplicationDefaults
      Organizations:
        - *Org1
EOF

# ── Bring the network up
echo "🧹 Bringing down any running stack…"
"${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" down -v --remove-orphans || true
"${DOCKER_CMD[@]}" network rm "$NETWORK_NAME" 2>/dev/null || true

echo "📦 Bringing up orderers and peers with $COMPOSE_FILE…"
"${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d

echo "⏳ Waiting for containers to settle…"
sleep 8

# ── Create application channel block
echo "🧱 Generating channel block ($CHANNEL_NAME)…"
configtxgen -configPath ./configtx \
  -profile "$PROFILE_NAME" \
  -outputBlock ./channel-artifacts/"$CHANNEL_NAME".block \
  -channelID "$CHANNEL_NAME"

# ── Join orderers via participation API (with a tiny retry)
join_orderer() {
  local addr="$1"
  for i in {1..10}; do
    if osnadmin channel join \
      --channelID "$CHANNEL_NAME" \
      --config-block ./channel-artifacts/"$CHANNEL_NAME".block \
      -o "$addr" \
      --ca-file "$ORDERER_CA" \
      --client-cert "$ORD_ADMIN_CERT" \
      --client-key "$ORD_ADMIN_KEY"; then
      echo "✅ Orderer at $addr joined $CHANNEL_NAME"
      return 0
    fi
    echo "…retry $i joining orderer at $addr"
    sleep 2
  done
  return 1
}

echo "🧩 Joining orderers to $CHANNEL_NAME…"
join_orderer "$ORDERER1_ADMIN_ADDR"
join_orderer "$ORDERER2_ADMIN_ADDR"
join_orderer "$ORDERER3_ADMIN_ADDR"

# ── Join peers
echo "🤝 Joining peers to $CHANNEL_NAME…"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="$ORG1_MSP"
export CORE_PEER_MSPCONFIGPATH="$ORG1_ADMIN_MSP"

export CORE_PEER_TLS_ROOTCERT_FILE="$BASE/organizations/peerOrganizations/org1.adrenaline.com/peers/peer0.org1.adrenaline.com/tls/ca.crt"
export CORE_PEER_ADDRESS="$PEER0_ADDR"
peer channel join -b ./channel-artifacts/"$CHANNEL_NAME".block

export CORE_PEER_TLS_ROOTCERT_FILE="$BASE/organizations/peerOrganizations/org1.adrenaline.com/peers/peer1.org1.adrenaline.com/tls/ca.crt"
export CORE_PEER_ADDRESS="$PEER1_ADDR"
peer channel join -b ./channel-artifacts/"$CHANNEL_NAME".block

export CORE_PEER_TLS_ROOTCERT_FILE="$BASE/organizations/peerOrganizations/org1.adrenaline.com/peers/peer2.org1.adrenaline.com/tls/ca.crt"
export CORE_PEER_ADDRESS="$PEER2_ADDR"
peer channel join -b ./channel-artifacts/"$CHANNEL_NAME".block

# ── Set anchor peers (three anchors)
echo "📡 Setting anchor peers…"
export CORE_PEER_TLS_ROOTCERT_FILE="$BASE/organizations/peerOrganizations/org1.adrenaline.com/peers/peer0.org1.adrenaline.com/tls/ca.crt"
export CORE_PEER_ADDRESS="$PEER0_ADDR"

# small retry for fetch
for i in {1..10}; do
  if peer channel fetch config ./channel-artifacts/config_block.pb \
    -o "$ORDERER1_ADDR" \
    --ordererTLSHostnameOverride orderer.adrenaline.com \
    -c "$CHANNEL_NAME" --tls --cafile "$ORDERER_CA"; then
    break
  fi
  echo "…retry $i fetching config block"
  sleep 2
done

configtxlator proto_decode --input channel-artifacts/config_block.pb --type common.Block --output channel-artifacts/config_block.json
jq '.data.data[0].payload.data.config' channel-artifacts/config_block.json > channel-artifacts/config.json
cp channel-artifacts/config.json channel-artifacts/config_copy.json

jq '.channel_group.groups.Application.groups.Org1MSP.values += {
  "AnchorPeers":{
    "mod_policy":"Admins",
    "value":{"anchor_peers":[
      {"host":"peer0.org1.adrenaline.com","port":7051},
      {"host":"peer1.org1.adrenaline.com","port":8051},
      {"host":"peer2.org1.adrenaline.com","port":9051}
    ]},
    "version":"0"
  }
}' channel-artifacts/config_copy.json > channel-artifacts/modified_config.json

configtxlator proto_encode --input channel-artifacts/config.json --type common.Config --output channel-artifacts/config.pb
configtxlator proto_encode --input channel-artifacts/modified_config.json --type common.Config --output channel-artifacts/modified_config.pb
configtxlator compute_update --channel_id "$CHANNEL_NAME" --original channel-artifacts/config.pb --updated channel-artifacts/modified_config.pb --output channel-artifacts/config_update.pb
configtxlator proto_decode --input channel-artifacts/config_update.pb --type common.ConfigUpdate --output channel-artifacts/config_update.json
echo '{"payload":{"header":{"channel_header":{"channel_id":"'"$CHANNEL_NAME"'", "type":2}},"data":{"config_update":'$(cat channel-artifacts/config_update.json)'}}}' \
  | jq . > channel-artifacts/config_update_in_envelope.json
configtxlator proto_encode --input channel-artifacts/config_update_in_envelope.json --type common.Envelope --output channel-artifacts/config_update_in_envelope.pb

peer channel update \
  -f channel-artifacts/config_update_in_envelope.pb \
  -c "$CHANNEL_NAME" \
  -o "$ORDERER1_ADDR" \
  --ordererTLSHostnameOverride orderer.adrenaline.com \
  --tls --cafile "$ORDERER_CA"

echo "🎉 Done. Channel: $CHANNEL_NAME"
