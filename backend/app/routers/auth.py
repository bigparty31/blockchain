import logging

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import login_limit
from app.auth.deps import get_current_user
from app.auth.security import create_access_token, verify_password
from app.auth.users import SEED_USERS, User, get_user_by_student_no
from app.database import get_db
from app.schemas.auth import LoginRequest, LoginResponse, MeResponse

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["Auth"])

# 없는 학번도 비밀번호 검사 시간을 똑같이 써서, 응답 시간으로 학번 존재 여부가 드러나지 않게 한다
_DUMMY_HASH = SEED_USERS[0].password_hash


def _db_unavailable() -> HTTPException:
    # 실패 횟수를 확인할 수 없으면 로그인도 받지 않는다. 받으면 DB 를 흔드는 동안 제한이 없어진다
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="로그인을 처리할 수 없습니다. 잠시 후 다시 시도해 주세요.",
    )


@router.post(
    "/login",
    response_model=LoginResponse,
    summary="로그인 (세션 JWT 발급)",
    responses={
        401: {"description": "학번 또는 비밀번호가 올바르지 않음"},
        429: {"description": "연속 실패로 잠김. Retry-After 헤더(초) 뒤에 다시 시도"},
        503: {"description": "DB 오류로 실패 횟수를 확인할 수 없음"},
    },
)
def login(req: LoginRequest, db: Session = Depends(get_db)):
    """학번과 비밀번호로 로그인하고 세션 JWT 와 역할(role)을 발급합니다.
    이후 요청은 `Authorization: Bearer <access_token>` 헤더로 보냅니다.

    같은 학번으로 연속 5회 실패하면 15분 동안 `429` 입니다 (맞는 비밀번호도 거부).
    """
    # async 가 아닌 def 로 둔다. bcrypt 검사(~0.2초 CPU)를 FastAPI 가 스레드풀에서 돌려
    # 그동안 다른 요청이 멈추지 않는다.
    try:
        attempt = login_limit.reserve(db, req.student_no)
    except SQLAlchemyError:
        db.rollback()
        logger.exception("로그인 시도 기록 중 데이터베이스 오류")
        raise _db_unavailable()

    if attempt.retry_after is not None:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="로그인 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.",
            headers={"Retry-After": str(attempt.retry_after)},
        )

    user = get_user_by_student_no(req.student_no)
    password_ok = verify_password(req.password, user.password_hash if user else _DUMMY_HASH)
    ok = user is not None and password_ok

    try:
        if ok:
            login_limit.clear(db, req.student_no)
        else:
            login_limit.record_failure(db, attempt)
    except SQLAlchemyError:
        db.rollback()
        logger.exception("로그인 결과 기록 중 데이터베이스 오류")
        raise _db_unavailable()

    if not ok:
        # 학번이 틀렸는지 비밀번호가 틀렸는지 구분하지 않는다
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="학번 또는 비밀번호가 올바르지 않습니다.",
        )

    return LoginResponse(
        access_token=create_access_token(user.id),
        token_type="bearer",
        role=user.role,
        name=user.name,
        wallet_address=user.wallet_address,
    )


@router.get("/me", response_model=MeResponse, summary="내 정보 조회")
async def me(user: User = Depends(get_current_user)):
    """현재 로그인한 사용자의 기본 프로필과 권한을 반환합니다."""
    return MeResponse(id=user.id, student_no=user.student_no, name=user.name, role=user.role)
