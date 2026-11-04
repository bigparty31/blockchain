"""CLOVA OCR General 호출.

키는 저장소 루트 .env 의 OCR_API_KEY(도메인 Secret Key)와 OCR_INVOKE_URL(APIGW Invoke URL)에서 읽는다.
네이버 클라우드 플랫폼 API 인증키(Access Key)가 아니다 — 그 키로는 OCR 을 호출할 수 없다.

라우터는 Depends(get_ocr_client) 로 받는다. 테스트는 dependency_overrides 로 가짜를 끼워 CLOVA 를 부르지 않는다.
키가 없거나 CLOVA 가 응답하지 않으면 OcrUnavailable 을 던지고, 라우터가 UNREADABLE 로 바꾼다 (등록을 막지 않는다, PRD §6).
"""
import base64
import logging
import os
import time
import uuid
from typing import Optional, Protocol

import aiohttp

logger = logging.getLogger(__name__)

TIMEOUT_SECONDS = 15


class OcrUnavailable(Exception):
    """OCR 을 돌리지 못함 (키 없음·네트워크·CLOVA 오류). 영수증이 흐린 것과는 다르다."""


class OcrClient(Protocol):
    async def recognize(self, image: bytes, image_format: str) -> dict:
        """CLOVA General 응답 JSON 을 dict 로 돌려준다."""
        ...


def build_request(image: bytes, image_format: str) -> dict:
    """CLOVA General V2 요청 본문. 표 영역(tables)도 같이 받는다 (docs/OCR.md)."""
    return {
        "version": "V2",
        "requestId": str(uuid.uuid4()),
        "timestamp": int(time.time() * 1000),
        "lang": "ko",
        "enableTableDetection": True,
        "images": [{"format": image_format, "name": "receipt", "data": base64.b64encode(image).decode("ascii")}],
    }


class ClovaOcrClient:
    def __init__(self, invoke_url: Optional[str], secret: Optional[str]):
        self.invoke_url = invoke_url
        self.secret = secret

    async def recognize(self, image: bytes, image_format: str) -> dict:
        if not self.invoke_url or not self.secret:
            raise OcrUnavailable("OCR_API_KEY 또는 OCR_INVOKE_URL 이 설정되지 않았다")
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=TIMEOUT_SECONDS)) as session:
                async with session.post(
                    self.invoke_url,
                    json=build_request(image, image_format),
                    headers={"X-OCR-SECRET": self.secret},
                ) as res:
                    if res.status != 200:
                        # 본문에 키가 들어 있을 일은 없지만, 로그에는 상태 코드와 앞부분만 남긴다
                        body = (await res.text())[:200]
                        raise OcrUnavailable(f"CLOVA 응답 {res.status}: {body}")
                    return await res.json()
        except (aiohttp.ClientError, OSError) as e:  # aiohttp 타임아웃은 OSError 계열 (app/chain/web3_client.py 와 같음)
            raise OcrUnavailable(f"CLOVA 연결 실패: {e!r}") from e


def get_ocr_client() -> OcrClient:
    return ClovaOcrClient(os.environ.get("OCR_INVOKE_URL"), os.environ.get("OCR_API_KEY"))
