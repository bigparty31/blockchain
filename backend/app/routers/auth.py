from fastapi import APIRouter, Depends, HTTPException, status

from app.auth.deps import get_current_user
from app.auth.security import create_access_token, verify_password
from app.auth.users import SEED_USERS, User, get_user_by_student_no
from app.schemas.auth import LoginRequest, LoginResponse, MeResponse

router = APIRouter(prefix="/auth", tags=["Auth"])

# 없는 학번도 비밀번호 검사 시간을 똑같이 써서, 응답 시간으로 학번 존재 여부가 드러나지 않게 한다
_DUMMY_HASH = SEED_USERS[0].password_hash


@router.post("/login", response_model=LoginResponse, summary="로그인 (세션 JWT 발급)")
async def login(req: LoginRequest):
    """학번과 비밀번호로 로그인하고 세션 JWT 와 역할(role)을 발급합니다.
    이후 요청은 `Authorization: Bearer <access_token>` 헤더로 보냅니다.
    """
    user = get_user_by_student_no(req.student_no)
    password_ok = verify_password(req.password, user.password_hash if user else _DUMMY_HASH)
    if user is None or not password_ok:
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
