"""자기 승인 차단 (ensure_not_self_approval).

승인·반려 API가 아직 없어 함수를 직접 호출한다. API에 붙이면 그 API 테스트에서도 확인한다.
"""
import pytest
from fastapi import HTTPException

from app.auth import ensure_not_self_approval
from app.schemas.auth import Role


class _DummyEntry:
    pass



def test_blocks_registrant_whose_role_changed_to_president(seed_user):
    # 등록은 총무만 할 수 있으므로, 자기 승인은 총무로 등록한 사람이 임기 중 회장이 된 경우에 생긴다.
    # 역할 검사는 통과하지만 자기 건은 막아야 한다
    registrant = seed_user(Role.TREASURER)
    now_president = registrant.model_copy(update={"role": Role.PRESIDENT})
    with pytest.raises(HTTPException) as exc:
        ensure_not_self_approval(registrant.id, now_president)
    assert exc.value.status_code == 403
    assert exc.value.detail == "본인이 등록한 항목은 승인·반려할 수 없습니다."


@pytest.mark.parametrize("role", [Role.AUDITOR, Role.PRESIDENT])
def test_other_user_can_approve(role, seed_user):
    # 예외 없이 지나가면 통과
    ensure_not_self_approval(seed_user(Role.TREASURER).id, seed_user(role))


@pytest.mark.parametrize(
    "wrong_created_by",
    [_DummyEntry(), "2", 2.0, True],
    ids=["entry-object", "str-id", "float-id", "bool"],
)
def test_wrong_created_by_type_fails_loudly(wrong_created_by, seed_user):
    # entry.created_by 대신 다른 값을 넘기면 == 비교가 늘 거짓이라 조용히 통과해 버린다
    with pytest.raises(TypeError):
        ensure_not_self_approval(wrong_created_by, seed_user(Role.AUDITOR))
