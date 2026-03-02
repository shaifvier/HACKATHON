#!/bin/bash

# Define peer admin paths and corresponding IPs
PEER_IPS=("localhost:7051" "localhost:8051" "localhost:9051")
PEER_NAMES=("peer0.org1.adrenaline.com" "peer1.org1.adrenaline.com" "peer2.org1.adrenaline.com")

ORDERER_CA="$HOME/fabric-samples/test-network/organizations/ordererOrganizations/adrenaline.com/orderers/orderer.adrenaline.com/tls/ca.crt"
CHAINCODE_PATH="$HOME/fabric-samples/test-network/chaincode"
PACKAGE_PATH="${CHAINCODE_PATH}/package"
CHANNEL_NAME="channel1"
CHAINCODE_NAME="pqc_chaincode"
CHAINCODE_LABEL="PQC_v1"
CHAINCODE_VERSION="1.0"
SEQUENCE="1"
ORDERER_ENDPOINT="localhost:7050"
CCAAS_SERVER_PORT=9999


export PATH="$HOME/fabric-samples/bin:$PATH"
export CORE_PEER_TLS_ENABLED=true 
export CORE_PEER_LOCALMSPID='Org1MSP' 
export FABRIC_CFG_PATH=$HOME/fabric-samples/config
export CORE_PEER_MSPCONFIGPATH=$HOME/fabric-samples/test-network/organizations/peerOrganizations/org1.adrenaline.com/users/Admin@org1.adrenaline.com/msp 

# Step 1: Package the chaincode for CCAAS

# Define a function for packaging the Chaincode-as-a-Service
packageChaincode() {
    echo "📦 Packaging the Chaincode-as-a-Service..."

    # Ensure package directory exists
    mkdir -p "${PACKAGE_PATH}"

    # Create a temporary directory for packaging
    prefix=$(basename "$0")
    tempdir=$(mktemp -d -t "$prefix.XXXXXXXX") || { echo "Error creating temp directory"; exit 1; }
    label="${CHAINCODE_NAME}_${CHAINCODE_VERSION}"

    # Ensure directories exist
    mkdir -p "$tempdir/src"
    mkdir -p "$tempdir/pkg"

    # Generate connection.json
    cat > "$tempdir/src/connection.json" <<EOF
{
  "address": "pqc_chaincode:${CCAAS_SERVER_PORT}",
  "dial_timeout": "10s",
  "tls_required": false
}
EOF

    # Generate metadata.json
    cat > "$tempdir/pkg/metadata.json" <<EOF
{
  "type": "ccaas",
  "label": "${label}"
}
EOF

    # Create `code.tar.gz` containing `connection.json`
    tar -C "$tempdir/src" -czf "$tempdir/pkg/code.tar.gz" connection.json

    # Create the final chaincode package including `metadata.json` and `code.tar.gz`
    tar -C "$tempdir/pkg" -czf "${PACKAGE_PATH}/${CHAINCODE_NAME}.tar.gz" metadata.json code.tar.gz

    # Cleanup temporary files
    rm -rf "$tempdir"

    # Verify Package ID
    PACKAGE_ID=$(peer lifecycle chaincode calculatepackageid "${PACKAGE_PATH}/${CHAINCODE_NAME}.tar.gz")
    echo "✅ Chaincode package created: ${PACKAGE_PATH}/${CHAINCODE_NAME}.tar.gz"
    echo "📦 Package ID: ${PACKAGE_ID}"
}

# Call the function to package the chaincode
packageChaincode

# Step 2: Install the chaincode on all peers
for i in "${!PEER_IPS[@]}"; do
  echo "📥 Installing chaincode on ${PEER_NAMES[$i]}..."
  export CORE_PEER_TLS_ROOTCERT_FILE=$HOME/fabric-samples/test-network/organizations/peerOrganizations/org1.adrenaline.com/peers/${PEER_NAMES[$i]}/tls/ca.crt 
  export CORE_PEER_ADDRESS=${PEER_IPS[$i]} 
  peer lifecycle chaincode install ${PACKAGE_PATH}/${CHAINCODE_NAME}.tar.gz
done

# Step 3: Get package ID
if [[ -z "$PACKAGE_ID" ]]; then
    echo "❌ ERROR: Failed to retrieve package ID!"
    exit 1
fi

echo "🔍 Using Package ID: $PACKAGE_ID"

# Step 4: Approve the chaincode definition on all peers

# Get the latest committed sequence
LATEST_SEQUENCE=$(peer lifecycle chaincode querycommitted --channelID ${CHANNEL_NAME} --name ${CHAINCODE_NAME} | awk -F 'Sequence: ' '{print $2}' | awk '{print $1}' | tr -d ',')


if [[ -z "$LATEST_SEQUENCE" ]]; then
    SEQUENCE=1  # First deployment
    CHAINCODE_VERSION="1.0"
else
    SEQUENCE=$((LATEST_SEQUENCE + 1))  # Increment for upgrades
    # Increment version accordingly
    LATEST_VERSION=$(peer lifecycle chaincode querycommitted --channelID ${CHANNEL_NAME} --name ${CHAINCODE_NAME} | awk '/Version:/ {print $2}' | tr -d '",')
fi

echo "🔍 Latest committed sequence: ${LATEST_SEQUENCE}"
echo "📢 Using sequence number: ${SEQUENCE}"
echo "📢 Using chaincode version: ${LATEST_VERSION}"

#for i in "${!PEER_IPS[@]}"; do
echo "✅ Approving chaincode on ${PEER_NAMES[0]}..."
export CORE_PEER_TLS_ROOTCERT_FILE=$HOME/fabric-samples/test-network/organizations/peerOrganizations/org1.adrenaline.com/peers/${PEER_NAMES[0]}/tls/ca.crt 
export CORE_PEER_ADDRESS=${PEER_IPS[0]} 
peer lifecycle chaincode approveformyorg -o ${ORDERER_ENDPOINT} --ordererTLSHostnameOverride orderer.adrenaline.com --tls --cafile ${ORDERER_CA} --channelID ${CHANNEL_NAME} --name ${CHAINCODE_NAME} --version ${CHAINCODE_VERSION} --package-id ${PACKAGE_ID} --sequence ${SEQUENCE} 

#done

# Step 5: Commit the chaincode definition

echo "🚀 Committing the chaincode on ${CHANNEL_NAME}..."
peer lifecycle chaincode commit -o ${ORDERER_ENDPOINT} --ordererTLSHostnameOverride orderer.adrenaline.com --tls --cafile ${ORDERER_CA} --channelID ${CHANNEL_NAME} --name ${CHAINCODE_NAME} --version ${CHAINCODE_VERSION} --sequence ${SEQUENCE} 


echo "✅ Chaincode installed, approved, and committed on all peers."

# Step 6: Build and run Chaincode Docker container
echo "🐳 Building the chaincode Docker image..."
docker build -t pqc_chaincode:latest $CHAINCODE_PATH

echo "🚀 Running the Chaincode-as-a-Service container..."
docker run -d --rm --name pqc_chaincode \
  --network fabric_adrenaline \
  -e CHAINCODE_SERVER_ADDRESS=0.0.0.0:${CCAAS_SERVER_PORT} \
  -e CHAINCODE_ID=${PACKAGE_ID} -e CORE_CHAINCODE_ID_NAME=${PACKAGE_ID} \
  pqc_chaincode:latest

echo "🎉 Chaincode-as-a-Service is now running!"
