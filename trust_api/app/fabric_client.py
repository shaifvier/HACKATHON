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
            env=os.environ.copy(),
            check=False,
        )
        output = (process.stdout or "") + (process.stderr or "")
        if process.returncode != 0:
            raise FabricCommandError(output.strip() or "Fabric command failed")
        return output.strip()

    def invoke(self, function_name: str, function_args: list[str]) -> str:
        cc_payload = json.dumps({"Args": [function_name, *function_args]})
        cmd = [
            "./network.sh",
            "cc",
            "invoke",
            "-org",
            str(self.org),
            "-c",
            self.channel_name,
            "-ccn",
            self.chaincode_name,
            "-ccic",
            cc_payload,
        ]
        return self._run(cmd)

    def query(self, function_name: str, function_args: list[str]) -> Any:
        cc_payload = json.dumps({"Args": [function_name, *function_args]})
        cmd = [
            "./network.sh",
            "cc",
            "query",
            "-org",
            str(self.org),
            "-c",
            self.channel_name,
            "-ccn",
            self.chaincode_name,
            "-ccqc",
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
