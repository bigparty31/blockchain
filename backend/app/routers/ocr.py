import base64
import binascii
import logging

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import User, require_roles
from app.database import get_db
from app.models import Entry as DBEntry
from app.ocr import OcrClient, OcrUnavailable, ParsedReceipt, get_ocr_client, judge, parse_clova_response
from app.ocr.readings import is_confident, receipt_hash_of, save_reading
from app.schemas.auth import Role
from app.schemas.entry import OCRStatus
from app.schemas.ocr import OcrRequest, OcrResult

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/ocr", tags=["OCR"])

treasurer_only = require_roles(Role.TREASURER)

MAX_IMAGE_BYTES = 10 * 1024 * 1024  # 휴대폰 사진 한 장 기준 넉넉히

# 중복 비교 대상. 반려(REJECTED)·차단(BLOCKED) 건은 같은 영수증으로 다시 올리는 것이 정상 경로라 뺀다
# (T4 반려 후 재등록 §4.3, 증액 후 재등록 §12-6). 초안은 체인에 올라가지 않아 중복 청구가 성립하지 않는다
DUPLICATE_TARGET_STATUSES = ("PENDING", "CONFIRMED")


@router.post("/receipt", response_model=OcrResult, summary="영수증 OCR 판독·판정 (판독값은 사진 해시로 저장)")
async def read_receipt(
    body: OcrRequest,
    user: User = Depends(treasurer_only),
    db: Session = Depends(get_db),
    ocr: OcrClient = Depends(get_ocr_client),
):
    """총무가 영수증을 찍은 직후 호출한다. 판독값과 판정(PRD §6)을 돌려준다.

    판독값은 사진 SHA-256(= 등록의 receipt_hash)으로 저장한다 (ocr_readings). 등록(POST /entries)은 앱이 보낸 ocr_* 가
    아니라 이 저장값과 입력 금액으로 **서버가 다시 판정한다** (#36 리뷰) — 이 응답의 판정은 총무에게 미리 알려 주는 용도다.

    차단이 아니라 경고라서, OCR 을 돌리지 못해도 오류 대신 UNREADABLE 을 돌려준다 — 등록은 계속할 수 있고
    승인 화면에 경고가 뜬다.
    """
    try:
        image = base64.b64decode(body.image_base64, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="image_base64 가 올바른 base64 가 아닙니다.")
    if not image:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="이미지가 비어 있습니다.")
    if len(image) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="이미지는 10MB 이하여야 합니다.")

    try:
        parsed = parse_clova_response(await ocr.recognize(image, body.format))
    except OcrUnavailable as e:
        logger.warning("OCR 호출 실패 — UNREADABLE 로 처리: %s", e)
        parsed = ParsedReceipt(readable=False, notes=[str(e)])

    receipt_hash = receipt_hash_of(image)
    try:
        save_reading(db, receipt_hash, parsed, user.id)
    except SQLAlchemyError as e:
        # 판독은 막지 않는다 — 저장을 못 했으면 등록 때 서버가 이 사진을 읽은 기록이 없어 UNREADABLE 로 남는다
        db.rollback()
        logger.exception("영수증 판독값 저장 중 데이터베이스 오류 — 등록 때 UNREADABLE 로 판정됨: %s", e)

    duplicate_of = None
    # 못 읽은 영수증은 중복 검사에서 뺀다 (PRD §6 UNREADABLE). 금액이 없거나 흐린 글자로 읽은 값으로 기존 건을 지목하지 않는다
    if is_confident(parsed) and parsed.approval_no and parsed.paid_at:
        try:
            existing = (
                db.query(DBEntry.id)
                .filter(
                    DBEntry.ocr_approval_no == parsed.approval_no,
                    DBEntry.ocr_paid_at == parsed.paid_at,
                    # 같은 영수증을 금액만 바꿔 다시 올려도 잡는다 — 판독 금액으로도 비교해야 DUPLICATE > MISMATCH 가 성립
                    DBEntry.amount.in_({body.amount, parsed.amount}),
                    DBEntry.status.in_(DUPLICATE_TARGET_STATUSES),
                )
                .order_by(DBEntry.id)
                .first()
            )
        except SQLAlchemyError as e:
            logger.exception("영수증 중복 조회 중 데이터베이스 오류: %s", e)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="데이터베이스 처리 중 오류가 발생했습니다.",
            )
        duplicate_of = existing.id if existing else None

    ocr_status = judge(parsed, body.amount, duplicate_of)
    return OcrResult(
        ocr_status=ocr_status,
        ocr_amount=parsed.amount,
        input_amount=body.amount,
        # 기존 건 링크는 DUPLICATE 판정일 때만 내려준다 (다른 상태에 링크가 붙으면 앱이 중복으로 오해한다)
        duplicate_of=duplicate_of if ocr_status == OCRStatus.DUPLICATE else None,
        ocr_approval_no=parsed.approval_no,
        ocr_paid_at=parsed.paid_at,
        receipt_hash=receipt_hash,
    )


# B9: 2서버 아키텍처용 라우터 별칭
command_router = router

