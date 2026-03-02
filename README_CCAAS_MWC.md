# Fabric test-network + CCaaS deployment (chaincode_MWC)

This guide deploys your selected chaincode (`chaincode_MWC.go`) as **Chaincode as a Service (CCaaS)** on a **simple Docker-based Hyperledger Fabric test-network**.

## What was added

- A dedicated CCaaS chaincode bundle at `src/ccaas_mwc/`.
- An end-to-end deployment script at `src/scripts/deploy_testnetwork_ccaas_mwc.sh`.

## Prerequisites

- Linux with Docker and bash.
- Internet access (to pull Fabric binaries/images and build dependencies).
- `fabric-samples` installed at `$HOME/fabric-samples`.

If `fabric-samples` is not installed:

```bash
cd $HOME
curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
chmod +x install-fabric.sh
./install-fabric.sh
```

## Deploy blockchain only (one-time)

From this repo root (`/home/ncl/pqc`):

```bash
chmod +x src/scripts/deploy_testnetwork_blockchain.sh
./src/scripts/deploy_testnetwork_blockchain.sh
```

This script only starts Fabric test-network and creates the channel.

## Deploy or update chaincode only

From this repo root (`/home/ncl/pqc`):

```bash
chmod +x src/scripts/deploy_testnetwork_ccaas_mwc.sh
./src/scripts/deploy_testnetwork_ccaas_mwc.sh
```

The script will:

1. Package and calculate CCaaS package ID.
2. Run lifecycle only when needed (first deploy, or forced upgrade).
3. Rebuild and restart chaincode service container (`pqc-mwc-ccaas`).

By default, if chaincode is already committed, lifecycle is skipped and only container rebuild/restart is done.

To force lifecycle upgrade (approve+commit with next sequence):

```bash
FORCE_LIFECYCLE=true ./src/scripts/deploy_testnetwork_ccaas_mwc.sh
```

## Verify

Tail chaincode logs:

```bash
docker logs -f pqc-mwc-ccaas
```

Run a query (from `fabric-samples/test-network`):

```bash
./network.sh cc query -org 1 -c mychannel -ccn pqc_mwc -ccqc '{"Args":["GetReputation","controllerA"]}'
```

This first query is expected to return “not found” unless state already exists.

## Cleanup

```bash
cd $HOME/fabric-samples/test-network
./network.sh down
docker rm -f pqc-mwc-ccaas 2>/dev/null || true
docker rmi pqc-mwc-ccaas:latest 2>/dev/null || true
```

## Notes

- Default channel: `mychannel`
- Default chaincode name: `pqc_mwc`
- Default service port: `9999`
- You can override variables when launching:

```bash
CHANNEL_NAME=mychannel CC_NAME=pqc_mwc CC_PORT=9999 ./src/scripts/deploy_testnetwork_ccaas_mwc.sh
```
