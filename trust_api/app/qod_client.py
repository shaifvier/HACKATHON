import json
import math
import os
import urllib.error
import urllib.request
from typing import Any


class QoDClientError(Exception):
    pass


class QoDClient:
    def __init__(self) -> None:
        self.platform = os.getenv("QOD_PLATFORM", "nokia_nac")
        self.auth_mode = os.getenv("QOD_AUTH_MODE", "rapidapi").lower()

        self.base_url = os.getenv("QOD_BASE_URL", "https://network-as-code.p-eu.rapidapi.com")
        self.create_session_path = os.getenv("QOD_CREATE_SESSION_PATH", "/qod/v0/sessions")
        fallback_raw = os.getenv(
            "QOD_CREATE_SESSION_PATH_FALLBACKS",
            "/quality-of-service-on-demand/v0.10.1/sessions,/quality-of-service-on-demand/v1/sessions",
        )
        self.create_session_fallback_paths = [
            value.strip() for value in fallback_raw.split(",") if value.strip()
        ]
        self.delete_session_path_template = os.getenv(
            "QOD_DELETE_SESSION_PATH_TEMPLATE", "/qod/v0/sessions/{sessionId}"
        )
        delete_fallback_raw = os.getenv(
            "QOD_DELETE_SESSION_PATH_FALLBACKS",
            "/quality-of-service-on-demand/v0.10.1/sessions/{sessionId},/quality-of-service-on-demand/v1/sessions/{sessionId}",
        )
        self.delete_session_fallback_path_templates = [
            value.strip() for value in delete_fallback_raw.split(",") if value.strip()
        ]

        self.api_key = os.getenv("QOD_API_KEY", "")
        self.api_host = os.getenv("QOD_API_HOST", "network-as-code.nokia.rapidapi.com")
        self.app_id = os.getenv("QOD_APP_ID", "")
        self.bearer_token = os.getenv("QOD_BEARER_TOKEN", "")

        self.qos_profile = os.getenv("QOD_PROFILE", "DOWNLINK_M_UPLINK_L")
        self.device_phone_number = os.getenv("QOD_DEVICE_PHONE_NUMBER", "").strip()
        self.device_public_ip = os.getenv("QOD_DEVICE_PUBLIC_IP", "84.78.248.189").strip()
        self.device_private_ip = os.getenv("QOD_DEVICE_PRIVATE_IP", "").strip()
        self.device_public_port = int(os.getenv("QOD_DEVICE_PUBLIC_PORT", "80"))
        self.app_server_ipv4 = os.getenv("QOD_APPLICATION_SERVER_IP", "3.127.127.197").strip()

    def _url(self, path: str) -> str:
        return f"{self.base_url.rstrip('/')}{path}"

    def _headers(self) -> dict[str, str]:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

        if self.auth_mode == "rapidapi":
            if self.api_key:
                headers["X-RapidAPI-Key"] = self.api_key
            if self.api_host:
                headers["X-RapidAPI-Host"] = self.api_host
            if self.app_id:
                headers["App"] = self.app_id
        elif self.auth_mode == "bearer":
            if self.bearer_token:
                headers["Authorization"] = f"Bearer {self.bearer_token}"

        return headers

    def _validate_auth(self) -> None:
        if self.auth_mode == "rapidapi" and not self.api_key:
            raise QoDClientError("QOD_API_KEY is not set (required for QOD_AUTH_MODE=rapidapi)")
        if self.auth_mode == "bearer" and not self.bearer_token:
            raise QoDClientError("QOD_BEARER_TOKEN is not set (required for QOD_AUTH_MODE=bearer)")
        if self.auth_mode not in {"rapidapi", "bearer"}:
            raise QoDClientError("QOD_AUTH_MODE must be 'rapidapi' or 'bearer'")

    def _payload(self, duration_seconds: int) -> dict[str, Any]:
        device: dict[str, Any] = {}

        if self.device_phone_number:
            device["phoneNumber"] = self.device_phone_number

        if self.device_public_ip:
            ipv4_address: dict[str, Any] = {
                "publicAddress": self.device_public_ip,
                "publicPort": self.device_public_port,
            }
            if self.device_private_ip:
                ipv4_address["privateAddress"] = self.device_private_ip
            device["ipv4Address"] = ipv4_address

        if not device:
            raise QoDClientError("QoD device identifier missing: set QOD_DEVICE_PHONE_NUMBER or QOD_DEVICE_PUBLIC_IP")

        if not self.app_server_ipv4:
            raise QoDClientError("QOD_APPLICATION_SERVER_IP is required")

        return {
            "qosProfile": self.qos_profile,
            "device": device,
            "applicationServer": {
                "ipv4Address": self.app_server_ipv4,
            },
            "duration": duration_seconds,
        }

    def create_session_for_trust_score(self, trust_score: int) -> dict[str, Any]:
        self._validate_auth()

        if trust_score < 0:
            raise QoDClientError("trust score must be >= 0")

        duration_seconds = max(1, trust_score)
        credits_used = max(1, math.ceil(duration_seconds / 60))

        payload = self._payload(duration_seconds)
        body = json.dumps(payload).encode("utf-8")
        paths_to_try = [self.create_session_path, *self.create_session_fallback_paths]
        tried: list[str] = []
        last_error: str | None = None

        for path in paths_to_try:
            req = urllib.request.Request(
                self._url(path),
                data=body,
                headers=self._headers(),
                method="POST",
            )
            tried.append(path)

            try:
                with urllib.request.urlopen(req, timeout=45) as response:
                    raw = response.read().decode("utf-8")
                    response_json = json.loads(raw) if raw else {}
                    return {
                        "sessionCreated": True,
                        "statusCode": response.getcode(),
                        "platform": self.platform,
                        "authMode": self.auth_mode,
                        "endpointUsed": path,
                        "credits": {
                            "policy": "score = session seconds, 1 credit per 60 seconds",
                            "trustScore": trust_score,
                            "secondsRequested": duration_seconds,
                            "creditsUsed": credits_used,
                        },
                        "requestPayload": payload,
                        "platformResponse": response_json,
                    }
            except urllib.error.HTTPError as err:
                err_body = err.read().decode("utf-8", errors="ignore")
                last_error = f"HTTP {err.code} on {path}: {err_body}"

                if err.code in {404, 405}:
                    continue
                raise QoDClientError(f"QoD API {last_error}") from err
            except urllib.error.URLError as err:
                raise QoDClientError(f"QoD API connection error: {err}") from err

        raise QoDClientError(
            f"QoD API endpoint not reachable for createSession. Tried: {tried}. Last error: {last_error}"
        )

    def delete_session(self, session_id: str) -> dict[str, Any]:
        self._validate_auth()

        if not session_id or not session_id.strip():
            raise QoDClientError("session_id is required")

        clean_session_id = session_id.strip()

        path_templates = [
            self.delete_session_path_template,
            *self.delete_session_fallback_path_templates,
        ]
        paths_to_try = [template.replace("{sessionId}", clean_session_id) for template in path_templates]

        tried: list[str] = []
        last_error: str | None = None

        for path in paths_to_try:
            req = urllib.request.Request(
                self._url(path),
                headers=self._headers(),
                method="DELETE",
            )
            tried.append(path)

            try:
                with urllib.request.urlopen(req, timeout=45) as response:
                    raw = response.read().decode("utf-8")
                    response_json = json.loads(raw) if raw else {}
                    return {
                        "sessionDeleted": True,
                        "statusCode": response.getcode(),
                        "platform": self.platform,
                        "authMode": self.auth_mode,
                        "endpointUsed": path,
                        "sessionId": clean_session_id,
                        "platformResponse": response_json,
                    }
            except urllib.error.HTTPError as err:
                err_body = err.read().decode("utf-8", errors="ignore")

                if err.code == 404:
                    return {
                        "sessionDeleted": False,
                        "statusCode": 404,
                        "platform": self.platform,
                        "authMode": self.auth_mode,
                        "endpointUsed": path,
                        "sessionId": clean_session_id,
                        "platformResponse": {"detail": err_body or "session not found"},
                    }

                last_error = f"HTTP {err.code} on {path}: {err_body}"
                if err.code in {405}:
                    continue
                raise QoDClientError(f"QoD API {last_error}") from err
            except urllib.error.URLError as err:
                raise QoDClientError(f"QoD API connection error: {err}") from err

        raise QoDClientError(
            f"QoD API endpoint not reachable for deleteSession. Tried: {tried}. Last error: {last_error}"
        )
