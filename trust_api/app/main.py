import os

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from app.fabric_client import FabricClient, FabricCommandError
from app.pqc_signer import PQCSigner


class PutTrustScoreRequest(BaseModel):
    score: int = Field(..., ge=0)


class PutTrustScoreResponse(BaseModel):
    id: str
    score: int
    signature: str
    signingPublicKey: str
    invokeOutput: str


def build_app() -> FastAPI:
    app = FastAPI(title="PQC Trust Score API", version="1.0.0")

    test_network_dir = os.getenv("TEST_NETWORK_DIR", os.path.expanduser("~/fabric-samples/test-network"))
    channel_name = os.getenv("CHANNEL_NAME", "mychannel")
    chaincode_name = os.getenv("CC_NAME", "pqc_mwc")
    org = int(os.getenv("ORG", "1"))
    key_dir = os.getenv("PQC_KEY_DIR", "./pqc_api_keys")
    pqc_algorithm = os.getenv("PQC_SIG_ALG", "Dilithium5")

    fabric = FabricClient(
        test_network_dir=test_network_dir,
        channel_name=channel_name,
        chaincode_name=chaincode_name,
        org=org,
    )
    signer = PQCSigner(key_dir=key_dir, algorithm=pqc_algorithm)

    @app.put("/trust-scores/{record_id}", response_model=PutTrustScoreResponse)
    def put_trust_score(record_id: str, payload: PutTrustScoreRequest) -> PutTrustScoreResponse:
        signature_b64 = signer.sign_reputation_update_b64(record_id, payload.score)
        signing_public_key_b64 = signer.public_key_b64

        try:
            invoke_output = fabric.invoke(
                "SetReputation",
                [record_id, str(payload.score), signature_b64, signing_public_key_b64],
            )
        except FabricCommandError as exc:
            raise HTTPException(status_code=500, detail=str(exc)) from exc

        return PutTrustScoreResponse(
            id=record_id,
            score=payload.score,
            signature=signature_b64,
            signingPublicKey=signing_public_key_b64,
            invokeOutput=invoke_output,
        )

    @app.get("/trust-scores/{record_id}")
    def get_trust_score(record_id: str):
        try:
            result = fabric.query("GetReputation", [record_id])
        except FabricCommandError as exc:
            detail = str(exc)
            if "not found" in detail.lower():
                raise HTTPException(status_code=404, detail=detail) from exc
            raise HTTPException(status_code=500, detail=detail) from exc
        return result

    return app


app = build_app()
