#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Deploying Fabric network (adrenaline) + pqc_chaincode (CCaaS)…"

BASE="$HOME/fabric-samples/test-network"
BIN="$HOME/fabric-samples/bin"
CFG="$HOME/fabric-samples/config"

COMPOSE_FILE="$BASE/compose/compose_pqc.yaml"
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

# ── Bring the network up
echo "🧹 Bringing down any running stack…"
docker-compose -f "$COMPOSE_FILE" down -v --remove-orphans || true
docker network rm "$NETWORK_NAME" 2>/dev/null || true

echo "📦 Bringing up orderers and peers with $COMPOSE_FILE…"
docker-compose -f "$COMPOSE_FILE" up -d

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
