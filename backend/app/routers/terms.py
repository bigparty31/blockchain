import logging
from typing import List
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy.exc import SQLAlchemyError

from app.database import get_db
from app.models import Term as DBTerm
from app.schemas.term import TermResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/terms", tags=["Terms"])
query_router = router


@router.get("", response_model=List[TermResponse], summary="학기 목록 조회")
@router.get("/", response_model=List[TermResponse], include_in_schema=False)
async def get_terms(db: Session = Depends(get_db)):
    """모바일 앱에서 온체인 학기 코드(term_code), 학기 명칭 등을 대조하기 위한 학기 목록 API입니다."""
    try:
        terms = db.query(DBTerm).order_by(DBTerm.id.asc()).all()
        return terms
    except SQLAlchemyError as e:
        logger.exception("학기 목록 조회 중 데이터베이스 오류 발생: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )


@router.get("/{id}", response_model=TermResponse, summary="학기 단건 상세 조회")
async def get_term_by_id(id: int, db: Session = Depends(get_db)):
    """특정 학기(ID)의 온체인 학기 코드 및 기간 상세 정보를 조회합니다."""
    try:
        term = db.query(DBTerm).filter(DBTerm.id == id).first()
    except SQLAlchemyError as e:
        logger.exception("학기 단건 조회 중 데이터베이스 오류 발생: %s", e)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="데이터베이스 처리 중 오류가 발생했습니다.",
        )

    if not term:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"ID {id}에 해당하는 학기를 찾을 수 없습니다.",
        )

    return term

