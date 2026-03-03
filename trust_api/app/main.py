import os
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from app.fabric_client import FabricClient, FabricCommandError
from app.pqc_signer import PQCSigner
from app.qod_client import QoDClient, QoDClientError


class PutTrustScoreRequest(BaseModel):
    score: int = Field(..., ge=0)


class PutTrustScoreResponse(BaseModel):
    id: str
    score: int
    signature: str
    signingPublicKey: str
    invokeOutput: str
    qodSession: dict


class GetTrustScoreResponse(BaseModel):
    trustRecord: dict
    qodSessionId: Optional[str] = None
    qodSessionCreatedAt: Optional[str] = None


class DeleteTrustSessionResponse(BaseModel):
    recordId: str
    deletedSessionId: str
    removedFromUser: bool
    qodDelete: dict


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
    qod = QoDClient()
    latest_qod_session_by_record: dict[str, str] = {}
    latest_qod_session_created_at_by_record: dict[str, str] = {}
    latest_qod_session_status_by_record: dict[str, str] = {}

    def resolve_session_created_at(qod_session: dict) -> str:
        platform_response = qod_session.get("platformResponse", {})
        for key in (
            "createdAt",
            "creationDate",
            "createdDate",
            "startedAt",
            "startDate",
            "created",
        ):
            value = platform_response.get(key)
            if isinstance(value, str) and value.strip():
                return value

        return datetime.now(timezone.utc).isoformat()

    def resolve_session_qos_status(qod_session: dict) -> Optional[str]:
        platform_response = qod_session.get("platformResponse", {})
        for key in ("qosStatus", "status", "sessionStatus"):
            value = platform_response.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        return None

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

        try:
            qod_session = qod.create_session_for_trust_score(payload.score)
        except QoDClientError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

        session_id = qod_session.get("platformResponse", {}).get("sessionId")
        if isinstance(session_id, str) and session_id:
            latest_qod_session_by_record[record_id] = session_id
            latest_qod_session_created_at_by_record[record_id] = resolve_session_created_at(qod_session)
            session_status = resolve_session_qos_status(qod_session)
            if session_status:
                latest_qod_session_status_by_record[record_id] = session_status
            else:
                latest_qod_session_status_by_record.pop(record_id, None)

        return PutTrustScoreResponse(
            id=record_id,
            score=payload.score,
            signature=signature_b64,
            signingPublicKey=signing_public_key_b64,
            invokeOutput=invoke_output,
            qodSession=qod_session,
        )

    @app.get("/trust-scores/{record_id}")
    def get_trust_score(record_id: str) -> GetTrustScoreResponse:
        try:
            trust_record = fabric.query("GetReputation", [record_id])
        except FabricCommandError as exc:
            detail = str(exc)
            if "not found" in detail.lower():
                raise HTTPException(status_code=404, detail=detail) from exc
            raise HTTPException(status_code=500, detail=detail) from exc

        trust_record_view = dict(trust_record)
        trust_record_view.pop("signature", None)
        trust_record_view.pop("signingPublicKey", None)

        session_status = latest_qod_session_status_by_record.get(record_id, "")
        include_session = session_status.upper() in {"AVAILABLE", "REQUESTED"}

        return GetTrustScoreResponse(
            trustRecord=trust_record_view,
            qodSessionId=latest_qod_session_by_record.get(record_id) if include_session else None,
            qodSessionCreatedAt=latest_qod_session_created_at_by_record.get(record_id) if include_session else None,
        )

    @app.delete("/trust-scores/{record_id}/session", response_model=DeleteTrustSessionResponse)
    def delete_trust_session(record_id: str) -> DeleteTrustSessionResponse:
        session_id = latest_qod_session_by_record.get(record_id)
        if not session_id:
            raise HTTPException(status_code=404, detail="No QoD session found for user")

        try:
            qod_delete = qod.delete_session(session_id)
        except QoDClientError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

        latest_qod_session_by_record.pop(record_id, None)
        latest_qod_session_created_at_by_record.pop(record_id, None)
        latest_qod_session_status_by_record.pop(record_id, None)

        return DeleteTrustSessionResponse(
            recordId=record_id,
            deletedSessionId=session_id,
            removedFromUser=True,
            qodDelete=qod_delete,
        )

    return app


app = build_app()
