import base64
import hashlib
import os
from pathlib import Path

import oqs


class PQCSigner:
    def __init__(self, key_dir: str, algorithm: str = "Dilithium5") -> None:
        self.algorithm = algorithm
        self.key_dir = Path(key_dir)
        self.key_dir.mkdir(parents=True, exist_ok=True)

        self.secret_key_path = self.key_dir / "dilithium5_secret.bin"
        self.public_key_path = self.key_dir / "dilithium5_public.b64"

        self._secret_key: bytes
        self._public_key: bytes
        self._load_or_generate_keys()

    def _load_or_generate_keys(self) -> None:
        if self.secret_key_path.exists() and self.public_key_path.exists():
            self._secret_key = self.secret_key_path.read_bytes()
            self._public_key = base64.b64decode(self.public_key_path.read_text().strip())
            return

        with oqs.Signature(self.algorithm) as signer:
            self._public_key = signer.generate_keypair()
            self._secret_key = signer.export_secret_key()

        self.secret_key_path.write_bytes(self._secret_key)
        self.public_key_path.write_text(base64.b64encode(self._public_key).decode("utf-8"))
        os.chmod(self.secret_key_path, 0o600)

    @property
    def public_key_b64(self) -> str:
        return base64.b64encode(self._public_key).decode("utf-8")

    def sign_digest_b64(self, digest: bytes) -> str:
        with oqs.Signature(self.algorithm, secret_key=self._secret_key) as signer:
            signature = signer.sign(digest)
        return base64.b64encode(signature).decode("utf-8")

    def sign_reputation_update_b64(self, record_id: str, score: int) -> str:
        digest = hashlib.sha256(f"{record_id}:{score}".encode("utf-8")).digest()
        return self.sign_digest_b64(digest)
