from typing import Dict

from fastapi import APIRouter

from app.auth import users

router = APIRouter(prefix="/users", tags=["Users"])


@router.get("/wallets", response_model=Dict[str, str], summary="user id ↔ 지갑 주소 매핑 (검증 2단계)")
async def get_wallets():
    """체인의 `registrant`·`approver`(지갑 주소)를 DB의 `created_by`·`approved_by`(user id)와 대조할 때 쓰는 매핑입니다.

    - 키는 user id 문자열, 값은 EIP-55 체크섬 주소입니다. 비교할 때는 양쪽을 소문자로 맞춥니다.
    - 지갑이 등록된 사용자(현·전 임원)가 모두 들어 있습니다. 역할이 아니라 지갑 유무로 고르는 이유는, 임기가 끝난 사람이
      등록·승인한 과거 항목도 검증해야 하기 때문입니다. 지갑이 없는 학생은 체인에 서명자로 나오지 않아 빠집니다.
    - 다른 조회 API와 같이 토큰 없이 호출할 수 있습니다. 임원 주소는 체인에 이미 공개된 값입니다.
    """
    # 모듈에서 매번 읽는다. 목록을 import 시점에 복사해 두면 사용자 데이터가 바뀌어도 반영되지 않는다
    return {str(u.id): u.wallet_address for u in users.SEED_USERS if u.wallet_address}
