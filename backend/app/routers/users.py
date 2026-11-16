from typing import Dict

from fastapi import APIRouter, Depends
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.auth import users
from app.database import get_db
from app.models import User as DBUser

router = APIRouter(prefix="/users", tags=["Users"])
query_router = router


@router.get("/wallets", response_model=Dict[str, int], summary="지갑 주소 → user id 매핑 (검증 2단계)")
async def get_wallets(db: Session = Depends(get_db)):
    """체인의 `registrant`·`approver`(지갑 주소)를 DB의 `created_by`·`approved_by`(user id)와 대조할 때 쓰는 매핑입니다.

    - 키는 **소문자** 지갑 주소, 값은 user id(숫자)입니다. 앱은 체인 주소를 소문자로 바꿔 그대로 찾습니다.
    - 주소를 키로 두는 이유는 한 사람이 주소를 여러 개 가질 수 있어서입니다. 임원이 새 주소로 롤을 옮겨도
      (`RoleManager.changeRole`, 회장 키 분실 때는 회장 복구) 옛 주소로 등록·승인한 과거 항목은 체인에 옛 주소로 남습니다.
      지금은 사용자마다 현재 주소 하나만 들어 있고, 옛 주소는 롤 변경·회장 복구 릴레이를 붙일 때 같은 응답에 더해집니다
      (형식은 바뀌지 않습니다).
    - 지갑이 등록된 사용자(현·전 임원)가 모두 들어 있습니다. 역할이 아니라 지갑 유무로 고르는 이유는, 임기가 끝난 사람이
      등록·승인한 과거 항목도 검증해야 하기 때문입니다. 지갑이 없는 학생은 체인에 서명자로 나오지 않아 빠집니다.
    - 다른 조회 API와 같이 토큰 없이 호출할 수 있습니다. 임원 주소는 체인에 이미 공개된 값입니다.
    """
    # DB users 테이블이 있으면 그 지갑 주소를 우선 반영하고, 없으면 SEED_USERS 를 쓴다.
    db_wallets: Dict[int, str] = {}
    try:
        for uid, addr in db.query(DBUser.id, DBUser.wallet_address).all():
            if addr:
                db_wallets[uid] = addr
    except SQLAlchemyError:
        pass

    wallets: Dict[str, int] = {}

    def _put(uid: int, raw_addr: str) -> None:
        address = raw_addr.lower()
        # 두 사용자가 같은 주소를 가지면 dict 가 조용히 한쪽을 덮어써 서명자를 다른 사람으로 보여준다. 틀린 답보다 500 이 낫다
        if wallets.get(address, uid) != uid:
            raise RuntimeError(f"지갑 주소 {address} 가 user {wallets[address]}·{uid} 에 중복 등록되어 있다")
        wallets[address] = uid

    seen_ids = set()
    for u in users.SEED_USERS:
        seen_ids.add(u.id)
        raw_addr = db_wallets.get(u.id, u.wallet_address)
        if raw_addr:
            _put(u.id, raw_addr)

    for uid, raw_addr in db_wallets.items():
        if uid not in seen_ids:
            _put(uid, raw_addr)

    return wallets
