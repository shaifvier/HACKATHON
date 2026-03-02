#!/usr/bin/env python3
import os
import sys
import json
import base64
import hashlib
import argparse
from typing import Tuple, Dict

import oqs  # pip install liboqs-python (requires liboqs on the system)

# ──────────────────────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────────────────────
STORE_ROOT = os.environ.get("PQC_STORE", "./pqc_store")
KEM_ALG = "Kyber1024"
SIG_ALG = "Dilithium5"

# Filenames per controller
KEM_SK = "kem_secret.bin"
KEM_PK = "kem_public.b64"
SIG_SK = "sig_secret.bin"
SIG_PK = "sig_public.b64"

# Optional debug (CLI: --debug or env PQC_DEBUG=1)
DEBUG = False


# ──────────────────────────────────────────────────────────────────────────────
# IO helpers
# ──────────────────────────────────────────────────────────────────────────────
def ensure_dir(p: str):
    os.makedirs(p, exist_ok=True)

def b64read(path: str) -> bytes:
    with open(path, "rt", encoding="utf-8") as f:
        return base64.b64decode(f.read().strip())

def b64write(path: str, raw: bytes):
    with open(path, "wt", encoding="utf-8") as f:
        f.write(base64.b64encode(raw).decode())

def binread(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()

def binwrite(path: str, raw: bytes):
    with open(path, "wb") as f:
        f.write(raw)

def looks_base64(s: str) -> bool:
    try:
        base64.b64decode(s, validate=True)
        return True
    except Exception:
        return False


# ──────────────────────────────────────────────────────────────────────────────
# Caller ID normalisation
# ──────────────────────────────────────────────────────────────────────────────
def decode_caller_field(value: str) -> bytes:
    """
    Accepts:
      - Base64 of the x509::... string (from fetch_caller_ids output)
      - A raw 'x509::...' string
      - A CSV of ASCII codes ('101,68,85,...') for the Base64 text (or raw)
    Returns raw bytes of the x509::... string (we'll re-encode to Base64 text).
    """
    v = value.strip()

    # Prefer direct Base64 (most common from your fetch script)
    if looks_base64(v):
        return base64.b64decode(v)

    # CSV of digits?
    if all((ch.isdigit() or ch == ',' or ch.isspace()) for ch in v) and (',' in v):
        bytes_seq = bytes(int(x) for x in v.replace(" ", "").split(",") if x)
        # If that CSV actually encoded Base64 text, decode it
        try:
            maybe_text = bytes_seq.decode("utf-8", errors="ignore")
            if looks_base64(maybe_text):
                return base64.b64decode(maybe_text)
        except Exception:
            pass
        return bytes_seq

    # Fallback: treat as raw utf-8 text
    return v.encode("utf-8")


# ──────────────────────────────────────────────────────────────────────────────
# Identity (keys are generated once and then reused)
# ──────────────────────────────────────────────────────────────────────────────
class PQCIdentity:
    """
    Key material per controller:
    - Kyber KEM public/secret
    - Dilithium public/secret
    Keys are generated once and persisted; subsequent runs reuse them.
    """
    def __init__(self, dirpath: str, kem_alg: str = KEM_ALG, sig_alg: str = SIG_ALG):
        self.dir = dirpath
        self.kem_alg = kem_alg
        self.sig_alg = sig_alg
        ensure_dir(self.dir)
        self._load_or_generate()

    def _load_or_generate(self):
        kem_sk = os.path.join(self.dir, KEM_SK)
        kem_pk = os.path.join(self.dir, KEM_PK)
        sig_sk = os.path.join(self.dir, SIG_SK)
        sig_pk = os.path.join(self.dir, SIG_PK)

        have_all = all(os.path.exists(p) for p in (kem_sk, kem_pk, sig_sk, sig_pk))
        if have_all:
            self.kem_secret = binread(kem_sk)
            self.kem_public = b64read(kem_pk)
            self.sig_secret = binread(sig_sk)
            self.sig_public = b64read(sig_pk)
            return

        # Generate fresh keypairs (first run only)
        with oqs.KeyEncapsulation(self.kem_alg) as kem:
            self.kem_public = kem.generate_keypair()
            self.kem_secret = kem.export_secret_key()

        with oqs.Signature(self.sig_alg) as sig:
            self.sig_public = sig.generate_keypair()
            self.sig_secret = sig.export_secret_key()

        # Persist for reuse
        binwrite(kem_sk, self.kem_secret)
        b64write(kem_pk, self.kem_public)
        binwrite(sig_sk, self.sig_secret)
        b64write(sig_pk, self.sig_public)

    @property
    def kyber_public_b64(self) -> str:
        return base64.b64encode(self.kem_public).decode()

    @property
    def dilithium_public_b64(self) -> str:
        return base64.b64encode(self.sig_public).decode()

    def sign(self, message: bytes) -> bytes:
        with oqs.Signature(self.sig_alg, secret_key=self.sig_secret) as sig:
            return sig.sign(message)

    # For SubmitKey: sign SHA256(kyber_pubkey_bytes)
    def submitkey_signature_b64(self) -> str:
        digest = hashlib.sha256(self.kem_public).digest()
        sig = self.sign(digest)
        return base64.b64encode(sig).decode()

    # For RegisterController: sign given message bytes
    def register_signature_b64(self, msg_bytes: bytes) -> str:
        sig = self.sign(msg_bytes)
        return base64.b64encode(sig).decode()


# ──────────────────────────────────────────────────────────────────────────────
# Verification helpers (new API only: verify(msg, sig, public_key))
# ──────────────────────────────────────────────────────────────────────────────
def verify_sig(sig_alg: str, public_key: bytes, message: bytes, signature_b64: str) -> bool:
    try:
        signature = base64.b64decode(signature_b64)
    except Exception:
        if DEBUG:
            print("    ! base64 decode failed for signature")
        return False

    try:
        with oqs.Signature(sig_alg) as v:
            return bool(v.verify(message, signature, public_key))
    except Exception as e:
        if DEBUG:
            print(f"    ! verify exception: {e}")
        return False


# ──────────────────────────────────────────────────────────────────────────────
# Plumbing
# ──────────────────────────────────────────────────────────────────────────────
def sanitize_name(name: str) -> str:
    # Use folder-friendly names (no slashes, spaces, etc.)
    return "".join(ch if ch.isalnum() or ch in ("@", ".", "_", "-") else "_" for ch in name)

def process_controller(entry: dict, store_root: str) -> Tuple[dict, str]:
    """
    entry = { "name": "...", "caller_id": "<Base64 or other accepted format>" }
    Returns (output_record, store_dir_used)
    """
    name = entry.get("name") or "controller"
    caller_field = entry.get("caller_id", "")

    # Normalize caller to raw bytes (x509::... string)
    caller_raw = decode_caller_field(caller_field)

    # Create/load keys for this controller
    store_dir = os.path.join(store_root, sanitize_name(name))
    ident = PQCIdentity(store_dir)

    # --- Self-test: sign & verify a tiny message with this keypair ---
    try:
        test_msg = b"oqs-self-test"
        with oqs.Signature(ident.sig_alg, secret_key=ident.sig_secret) as s:
            test_sig = s.sign(test_msg)

        if not verify_sig(ident.sig_alg, ident.sig_public, test_msg, base64.b64encode(test_sig).decode()):
            raise RuntimeError("Self-test failed: signature did not verify with current liboqs API")
    except Exception as e:
        print(f"❌ {name}: liboqs self-test failed ({e}). "
              f"Check liboqs/liboqs-python versions and algorithm name '{ident.sig_alg}'.")
        sys.exit(1)

    # Normalised Base64 (of the RAW x509 bytes) — used for both JSON & register signature
    caller_id_b64_norm = base64.b64encode(caller_raw).decode("ascii")
    # ASCII bytes of that Base64 text (WhoAmI returns this form)
    caller_id_b64_text_bytes = caller_id_b64_norm.encode("ascii")

    out = {
        "name": name,

        # Always include the Base64 of RAW x509 bytes
        "caller_id_b64": caller_id_b64_norm,
        "caller_id_preview": caller_raw.decode("utf-8", errors="ignore")[:120],

        # PQC public keys
        "kyber_public_b64": ident.kyber_public_b64,
        "dilithium_public_b64": ident.dilithium_public_b64,

        # Signatures (only the two you need):
        #  1) SubmitKey (sign SHA256(raw Kyber pub))
        "submit_signature_b64": ident.submitkey_signature_b64(),
        #  2) Register over ASCII(Base64 text) — for WhoAmI(b64 text)
        "register_signature_over_b64text": ident.register_signature_b64(caller_id_b64_text_bytes),
    }

    if DEBUG:
        print("    [debug] kyber_pub_sha256 =", hashlib.sha256(ident.kem_public).hexdigest())
        print("    [debug] b64text_len      =", len(caller_id_b64_text_bytes))

    # Console verification (no JSON field added)
    print("🔍 Verifying signatures…")
    def p(label, ok):
        print(f"     - {label}: {'OK' if ok else 'FAIL'}")

    # 1) SubmitKey verification
    msg_submit = hashlib.sha256(ident.kem_public).digest()
    p("submit_signature_b64",
      verify_sig(ident.sig_alg, ident.sig_public, msg_submit, out["submit_signature_b64"]))

    # 2) Register over Base64-text verification
    p("register_signature_over_b64text",
      verify_sig(ident.sig_alg, ident.sig_public, caller_id_b64_text_bytes, out["register_signature_over_b64text"]))

    return out, store_dir


def main():
    global DEBUG

    ap = argparse.ArgumentParser(description="Build PQC material and signatures for multiple controllers.")
    ap.add_argument("-i", "--input", default="controllers.json",
                    help="Input JSON (array of {name, caller_id}) from fetch_caller_ids.js.")
    ap.add_argument("-o", "--output", default="pqc_output.json",
                    help="Where to write the output JSON.")
    ap.add_argument("--store", default=STORE_ROOT,
                    help="Where to store per-controller keys (default: ./pqc_store).")
    ap.add_argument("--debug", action="store_true",
                    help="Enable debug prints (or set env PQC_DEBUG=1).")
    args = ap.parse_args()

    DEBUG = args.debug or bool(os.environ.get("PQC_DEBUG"))

    store_root = args.store
    ensure_dir(store_root)

    # Load controllers list
    try:
        with open(args.input, "rt", encoding="utf-8") as f:
            controllers = json.load(f)
    except Exception as e:
        print(f"❌ Failed to read input '{args.input}': {e}")
        sys.exit(1)

    if not isinstance(controllers, list):
        print("❌ Input must be a JSON array of objects with fields: name, caller_id")
        sys.exit(1)

    results = []
    for entry in controllers:
        try:
            rec, store_dir = process_controller(entry, store_root)
            print(f"✅ {rec['name']}: keys at {store_dir}")
            results.append(rec)
        except Exception as e:
            print(f"❌ {entry.get('name','(unnamed)')}: {e}")
            sys.exit(1)

    # Guard against writing to a directory path by mistake
    try:
        if os.path.isdir(args.output):
            raise IsADirectoryError(f"'{args.output}' is a directory, not a file path")
        with open(args.output, "wt", encoding="utf-8") as f:
            json.dump(results, f, indent=2)
    except Exception as e:
        print(f"❌ Failed to write output '{args.output}': {e}")
        sys.exit(1)

    print(f"\n🎉 Wrote {len(results)} controller records to {args.output}")
    print("   Fields used by registration:")
    print("     - caller_id_b64")
    print("     - dilithium_public_b64")
    print("     - register_signature_over_b64text")


if __name__ == "__main__":
    main()
