import json
import os
import subprocess
from pathlib import Path
from typing import Any


class FabricCommandError(Exception):
    pass


class FabricClient:
    def __init__(
        self,
        test_network_dir: str,
        channel_name: str = "mychannel",
        chaincode_name: str = "pqc_mwc",
        org: int = 1,
    ) -> None:
        self.test_network_dir = Path(test_network_dir).expanduser()
        self.channel_name = channel_name
        self.chaincode_name = chaincode_name
        self.org = org

    def _fabric_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env["PATH"] = f"/fabric-samples/bin:{env.get('PATH', '')}"
        env["FABRIC_CFG_PATH"] = "/fabric-samples/config"
        env["CORE_PEER_TLS_ENABLED"] = "true"

        if self.org == 2:
            env["CORE_PEER_LOCALMSPID"] = "Org2MSP"
            env["CORE_PEER_ADDRESS"] = "peer0.org2.example.com:9051"
            env["CORE_PEER_TLS_ROOTCERT_FILE"] = (
                "/fabric-samples/test-network/organizations/peerOrganizations/"
                "org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
            )
            env["CORE_PEER_MSPCONFIGPATH"] = (
                "/fabric-samples/test-network/organizations/peerOrganizations/"
                "org2.example.com/users/Admin@org2.example.com/msp"
            )
        else:
            env["CORE_PEER_LOCALMSPID"] = "Org1MSP"
            env["CORE_PEER_ADDRESS"] = "peer0.org1.example.com:7051"
            env["CORE_PEER_TLS_ROOTCERT_FILE"] = (
                "/fabric-samples/test-network/organizations/peerOrganizations/"
                "org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
            )
            env["CORE_PEER_MSPCONFIGPATH"] = (
                "/fabric-samples/test-network/organizations/peerOrganizations/"
                "org1.example.com/users/Admin@org1.example.com/msp"
            )

        return env

    def _run(self, args: list[str]) -> str:
        if not self.test_network_dir.exists():
            raise FabricCommandError(
                f"test-network directory not found: {self.test_network_dir}"
            )

        process = subprocess.run(
            args,
            cwd=self.test_network_dir,
            text=True,
            capture_output=True,
            env=self._fabric_env(),
            check=False,
        )
        output = (process.stdout or "") + (process.stderr or "")
        if process.returncode != 0:
            raise FabricCommandError(output.strip() or "Fabric command failed")
        return output.strip()

    def invoke(self, function_name: str, function_args: list[str]) -> str:
        cc_payload = json.dumps({"Args": [function_name, *function_args]}, separators=(",", ":"))

        orderer_ca = (
            "/fabric-samples/test-network/organizations/ordererOrganizations/example.com/"
            "orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"
        )
        peer0_org1_ca = (
            "/fabric-samples/test-network/organizations/peerOrganizations/org1.example.com/"
            "peers/peer0.org1.example.com/tls/ca.crt"
        )
        peer0_org2_ca = (
            "/fabric-samples/test-network/organizations/peerOrganizations/org2.example.com/"
            "peers/peer0.org2.example.com/tls/ca.crt"
        )

        cmd = [
            "peer",
            "chaincode",
            "invoke",
            "-o",
            "orderer.example.com:7050",
            "--ordererTLSHostnameOverride",
            "orderer.example.com",
            "--tls",
            "--cafile",
            orderer_ca,
            "-C",
            self.channel_name,
            "-n",
            self.chaincode_name,
            "-c",
            cc_payload,
            "--peerAddresses",
            "peer0.org1.example.com:7051",
            "--tlsRootCertFiles",
            peer0_org1_ca,
            "--peerAddresses",
            "peer0.org2.example.com:9051",
            "--tlsRootCertFiles",
            peer0_org2_ca,
            "--waitForEvent",
        ]
        return self._run(cmd)

    def query(self, function_name: str, function_args: list[str]) -> Any:
        cc_payload = json.dumps({"Args": [function_name, *function_args]}, separators=(",", ":"))
        cmd = [
            "peer",
            "chaincode",
            "query",
            "-C",
            self.channel_name,
            "-n",
            self.chaincode_name,
            "-c",
            cc_payload,
        ]
        raw = self._run(cmd)

        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass

        start = raw.find("{")
        end = raw.rfind("}")
        if start != -1 and end != -1 and end > start:
            candidate = raw[start : end + 1]
            try:
                return json.loads(candidate)
            except json.JSONDecodeError:
                return {"raw": raw}

        return {"raw": raw}
