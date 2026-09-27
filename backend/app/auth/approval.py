from fastapi import HTTPException, status

from app.auth.users import User


def ensure_not_self_approval(created_by: int, approver: User) -> None:
    """등록자 본인이 승인·반려하려 하면 403 (docs/API.md §3 Maker-Checker).

    승인 API와 반려 API 모두 항목을 불러온 뒤 호출한다. 컨트랙트도 확정·반려 서명자가
    등록자와 같으면 revert(SelfApproval)하지만, 체인에 보내기 전에 서버가 먼저 막아
    릴레이 가스를 쓰지 않게 한다.

    승인 요청에는 기기 서명이 함께 오므로 이 검사는 승인자가 이미 서명한 뒤에 돈다.
    서명 전에 막는 것은 화면 몫이다 — 승인 목록에서 /auth/me 의 id 와 created_by 가 같으면
    버튼을 끈다.

    승인은 감사·회장만 할 수 있어 평소에는 역할 검사에서 걸러진다. 이 검사가 실제로 막는 것은
    임기 중 역할이 바뀐 경우다 — 총무로 등록한 사람이 회장이 된 뒤 자기 건을 승인하는 것.

        entry = ...  # 승인할 항목
        ensure_not_self_approval(entry.created_by, user)
    """
    # 항목 객체나 문자열 id 를 넘기면 == 비교가 늘 거짓이라 검사가 조용히 통과한다.
    # 잘못 부르면 막히는 쪽으로 실패하도록 타입부터 확인한다 (bool 도 거른다)
    if type(created_by) is not int:
        raise TypeError(f"created_by 는 등록자 user id(int)여야 합니다. 받은 값의 타입: {type(created_by).__name__}")
    if created_by == approver.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="본인이 등록한 항목은 승인·반려할 수 없습니다.",
        )
