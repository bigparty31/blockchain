"""PRD v0.15 §9.1 & §10: 학생용(student_api) 및 학생회용(council_api) 라우터 분리 검증 테스트.

"코드는 하나, 실행 단위는 둘" 원칙:
1. student_api:
   - 읽기 전용 DB 계정을 사용하므로 어떤 쓰기(Command) 엔드포인트도 마운트되어서는 안 된다.
   - 단, 학생 인증(POST /auth/login)은 DB 조회 기반이므로 허용된다.
   - 초안 목록(/entries/drafts), 증액 목록(/budget-revisions) 등 학생회 내부 관리용 조회도 제외된다.
2. council_api / main:
   - 모든 조회 및 쓰기/온체인 릴레이 엔드포인트를 마운트한다.
"""
from fastapi.testclient import TestClient
import pytest

from app.main import app as main_app
from app.main_student import app as student_app
from app.main_council import app as council_app


def _extract_routes(app):
    """FastAPI 앱의 OpenAPI 스키마(app.openapi()['paths'])에서 (method, path) 집합을 추출한다."""
    routes = set()
    for path, methods_dict in app.openapi().get("paths", {}).items():
        for method in methods_dict.keys():
            m = method.upper()
            if m not in ("HEAD", "OPTIONS", "PARAMETERS"):
                routes.add((m, path))
    return routes


def test_student_api_has_no_write_endpoints_except_auth():
    """student_api 에는 POST /auth/login 외에 어떠한 POST, PUT, DELETE, PATCH 엔드포인트도 없어야 한다."""
    routes = _extract_routes(student_app)
    assert len(routes) > 0

    disallowed_methods = {"POST", "PUT", "DELETE", "PATCH"}
    for method, path in routes:
        if method in disallowed_methods:
            # 유일하게 허용되는 예외: 인증(세션 JWT 발급용 POST /auth/login)
            assert (method, path) == ("POST", "/auth/login"), (
                f"student_api 에 허용되지 않은 쓰기 엔드포인트가 포함되어 있습니다: {method} {path}"
            )


def test_student_api_routes_whitelist():
    """student_api 가 노출하는 엔드포인트가 PRD §9.1 & §10 허용 목록과 정확히 일치하는지 검증한다."""
    routes = _extract_routes(student_app)

    expected_routes = {
        ("GET", "/"),
        ("POST", "/auth/login"),
        ("GET", "/auth/me"),
        ("GET", "/entries"),
        ("GET", "/entries/{id}"),
        ("GET", "/entries/{id}/onchain"),
        ("GET", "/balance"),
        ("GET", "/budgets"),
        ("GET", "/terms"),
        ("GET", "/terms/{id}"),
        ("GET", "/memberships/me"),
        ("GET", "/chain/domains"),
        ("GET", "/receipts/{filename}"),
        ("GET", "/users/wallets"),
    }

    assert routes == expected_routes, (
        f"student_api 엔드포인트 불일치.\n누락: {expected_routes - routes}\n초과: {routes - expected_routes}"
    )


def test_student_api_blocks_council_commands():
    """student_api 에 TestClient 로 쓰기/임원 전용 요청 시 404 또는 405 로 차단되는지 확인한다."""
    client = TestClient(student_app)

    # 1. 항목 초안 등록 시도 -> 404/405
    res = client.post("/entries", json={"term_id": 1, "kind": "INCOME", "amount": 1000})
    assert res.status_code in (404, 405)

    # 2. 항목 제출 시도 -> 404/405
    res = client.post("/entries/1/submit", json={"deadline": 1234, "signature": "0x123"})
    assert res.status_code in (404, 405)

    # 3. 항목 확정 시도 -> 404/405
    res = client.post("/entries/1/confirm", json={"deadline": 1234, "signature": "0x123"})
    assert res.status_code in (404, 405)

    # 4. 항목 수정 요청 시도 -> 404/405
    res = client.post("/entries/1/request-revision", json={"reason": "오타"})
    assert res.status_code in (404, 405)

    # 5. 초안 목록 조회 시도 -> student_api 에는 /entries/drafts 가 없으므로 404 이거나, /entries/{id} 가 낚아채 정수 검증 실패(422) 반환
    res = client.get("/entries/drafts")
    assert res.status_code in (404, 405, 422)

    # 6. 예산 발행 시도 -> 404/405
    res = client.post("/budgets", json={"term_id": 1, "category": "사업비", "planned_amount": 1000})
    assert res.status_code in (404, 405)

    # 7. 예산 개정/증액 시도 -> 404/405
    res = client.post("/budget-revisions", json={"term_id": 1, "category": "사업비", "amount": 1000})
    assert res.status_code in (404, 405)

    # 8. 예산 개정 목록 시도 -> 404/405
    res = client.get("/budget-revisions")
    assert res.status_code in (404, 405)

    # 9. 영수증 업로드 시도 -> 404/405
    res = client.post("/receipts")
    assert res.status_code in (404, 405)

    # 10. 임원 지갑 매핑 조회(검증 2단계)는 student_api 에서 정상 허용(200)되어야 한다
    res = client.get("/users/wallets")
    assert res.status_code == 200

    # 11. 영수증 파일 열람(GET /receipts/{filename})도 student_api 에 마운트되어 동일 저장소를 읽는다
    res = client.get("/receipts/0000000000000000000000000000000000000000000000000000000000000000.jpg")
    assert res.status_code == 404
    assert "영수증 파일" in res.json().get("detail", "")


def test_council_api_contains_all_routes():
    """council_api 및 main_app 은 모든 조회 및 쓰기 엔드포인트를 포함해야 한다."""
    council_routes = _extract_routes(council_app)
    main_routes = _extract_routes(main_app)

    # 필수 명령 엔드포인트 포함 검증
    required_commands = [
        ("POST", "/entries"),
        ("POST", "/entries/{id}/submit"),
        ("POST", "/entries/{id}/confirm"),
        ("POST", "/entries/{id}/reject"),
        ("POST", "/entries/{id}/request-revision"),
        ("GET", "/entries/drafts"),
        ("POST", "/budgets"),
        ("POST", "/budgets/{id}/submit"),
        ("POST", "/budget-revisions"),
        ("POST", "/budget-revisions/{id}/sign"),
        ("POST", "/budget-revisions/{id}/reject"),
        ("POST", "/budget-revisions/{id}/approve"),
        ("GET", "/budget-revisions"),
        ("POST", "/receipts"),
        ("GET", "/users/wallets"),
        ("GET", "/settlement/{term_id}"),
        ("POST", "/events"),
        ("GET", "/events"),
        ("POST", "/events/{event_id}/check-in"),
        ("POST", "/bank/snapshots"),
        ("POST", "/bank/snapshots/{snapshot_id}/rematch"),
        ("GET", "/bank/snapshots"),
        ("GET", "/bank/snapshots/{snapshot_id}"),
        ("GET", "/notifications"),
        ("GET", "/notifications/unread-count"),
        ("POST", "/notifications/{id}/read"),
        ("POST", "/notifications/device-tokens"),
        ("DELETE", "/notifications/device-tokens/{token}"),
    ]

    for req in required_commands:
        assert req in council_routes, f"council_api 에 필수 엔드포인트 {req} 가 누락되었습니다."

    assert council_routes == main_routes, (
        f"council_api 와 main_app 의 라우트 집합이 다릅니다.\n"
        f"council_api 누락: {main_routes - council_routes}\n"
        f"main_app 누락: {council_routes - main_routes}"
    )
