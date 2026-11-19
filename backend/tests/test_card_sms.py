"""카드 승인 문자 대조 테스트 — PRD v0.15 §4.6.

카드사별 파서(NH·KB)는 실제 문자 형식으로 따로 테스트한다. 여기서는 메시지 나누기·연도 추정·
승인/취소 상쇄·API 흐름을 카드사 형식과 상관없이 확인한다 (테스트용 파서를 잠깐 등록).
"""
import hashlib
import re
from datetime import datetime, timezone

import pytest

from app.bank import card_sms
from app.bank.card_sms import (
    APPROVAL,
    CANCEL,
    CardSms,
    CardSmsError,
    detect_company,
    pair_cancellations,
    resolve_date,
    split_messages,
)
from app.schemas.auth import Role
from test_bank_reconcile import add_entry, client, db_session, demo_ledger  # noqa: F401  (픽스처 재사용)

T_START = datetime(2026, 3, 1, tzinfo=timezone.utc)
T_END = datetime(2026, 6, 30, tzinfo=timezone.utc)


# ================================================================ 메시지 나누기·카드사


def test_split_by_web_sent():
    text = "[Web발신]\nNH 승인 A\n누적\n[Web발신]\nKB 승인 B\n\n[Web발신] NH 취소 C"
    assert split_messages(text) == ["[Web발신]\nNH 승인 A\n누적", "[Web발신]\nKB 승인 B", "[Web발신] NH 취소 C"]


def test_split_keeps_message_before_first_header_and_crlf():
    assert split_messages("NH 승인 A\r\n[Web발신]\r\nKB 승인 B\r\n") == ["NH 승인 A", "[Web발신]\nKB 승인 B"]


def test_split_by_blank_lines_without_header():
    assert split_messages("NH 승인 A\n줄2\n\n\nKB 승인 B\n") == ["NH 승인 A\n줄2", "KB 승인 B"]


def test_split_empty():
    assert split_messages(" \n\n ") == []


@pytest.mark.parametrize("msg,company", [
    ("[Web발신]\nNH카드 승인", "NH"),
    ("[Web발신]\n농협BC 승인", "NH"),
    ("[Web발신]\nKB국민카드 승인", "KB"),
    ("[Web발신]\n국민카드 승인", "KB"),
    ("[Web발신]\n신한카드 승인", None),
])
def test_detect_company(msg, company):
    assert detect_company(msg) == company


def test_unknown_company_unreadable():
    with pytest.raises(CardSmsError, match="카드사"):
        card_sms.parse_message("[Web발신]\n신한카드 승인 1,000원")


# ================================================================ 연도 추정


def test_resolve_date_within_term():
    assert resolve_date(3, 10, T_START, T_END) == "2026-03-10"
    assert resolve_date(7, 1, T_START, T_END) is None  # 학기 밖
    assert resolve_date(2, 30, T_START, T_END) is None  # 없는 날짜


def test_resolve_date_term_crossing_new_year():
    start, end = datetime(2026, 9, 1, tzinfo=timezone.utc), datetime(2027, 2, 28, tzinfo=timezone.utc)
    assert resolve_date(12, 20, start, end) == "2026-12-20"
    assert resolve_date(1, 15, start, end) == "2027-01-15"


# ================================================================ 승인·취소 상쇄


def sms(kind, amount=5000, merchant="OO편의점", no=None, company="NH"):
    return CardSms(company, kind, 3, 10, None, merchant, amount, no)


def test_pair_cancel_with_matching_approval():
    items = [(1, sms(APPROVAL)), (2, sms(APPROVAL, merchant="다른곳")), (3, sms(CANCEL))]
    assert pair_cancellations(items) == {1, 3}


def test_pair_one_to_one():
    # 같은 결제 2건 승인 + 1건 취소 → 한 쌍만 상쇄
    items = [(1, sms(APPROVAL)), (2, sms(APPROVAL)), (3, sms(CANCEL))]
    assert pair_cancellations(items) == {1, 3}


def test_pair_respects_approval_no_and_company():
    assert pair_cancellations([(1, sms(APPROVAL, no="111")), (2, sms(CANCEL, no="222"))]) == set()
    assert pair_cancellations([(1, sms(APPROVAL, no="111")), (2, sms(CANCEL))]) == {1, 2}  # 한쪽에 번호 없음
    assert pair_cancellations([(1, sms(APPROVAL)), (2, sms(CANCEL, company="KB"))]) == set()
    assert pair_cancellations([(1, sms(APPROVAL)), (2, sms(CANCEL, amount=4000))]) == set()


# ================================================================ API (테스트용 파서)

_FAKE = re.compile(r"NH (승인|취소) (\d{2})/(\d{2}) (\S+) (\d+)원(?: #(\d+))?")


def fake_nh(message: str) -> CardSms:
    m = _FAKE.search(message)
    if not m:
        raise CardSmsError("형식을 읽을 수 없습니다")
    kind, mo, d, merchant, amt, no = m.groups()
    return CardSms("NH", APPROVAL if kind == "승인" else CANCEL, int(mo), int(d), "12:00:00", merchant, int(amt), no)


@pytest.fixture
def fake_parser(monkeypatch):
    monkeypatch.setitem(card_sms._PARSERS, "NH", fake_nh)


def check(auth_header, text, role=Role.TREASURER, term_id=1):
    return client.post("/bank/card-sms/check", json={"term_id": term_id, "text": text}, headers=auth_header(role))


def test_card_sms_flow(db_session, auth_header, fake_parser):
    demo_ledger(db_session)  # 3/10 문구점 35,000, 3/12 식당 82,000 확정
    add_entry(db_session, 5, "EXPENSE", 9000, "2026-03-13", status="PENDING")
    text = "\n".join([
        "[Web발신]\nNH 승인 03/10 OO문구점 35000원",     # 1 확정과 짝
        "[Web발신]\nNH 승인 03/13 OO카페 9000원",        # 2 대기와 짝
        "[Web발신]\nNH 승인 03/18 OO편의점 12000원",     # 3 장부에 없음
        "[Web발신]\nNH 승인 03/19 OO매점 3000원 #77",    # 4 취소됨
        "[Web발신]\nNH 취소 03/19 OO매점 3000원 #77",    # 5 위와 상쇄
        "[Web발신]\nNH 승인 07/01 OO서점 1000원",        # 6 학기 밖
        "[Web발신]\nNH 알림 이상한 문자",                 # 7 못 읽음
        "[Web발신]\n신한카드 승인 1000원",                # 8 카드사 모름
    ])
    res = check(auth_header, text)
    assert res.status_code == 200
    body = res.json()
    got = [(i["msg_no"], i["status"], i["entry_id"]) for i in body["items"]]
    assert got == [
        (1, "MATCHED", 2), (2, "MATCHED_PENDING", 5), (3, "UNREGISTERED", None),
        (4, "CANCELLED_PAIR", None), (5, "CANCELLED_PAIR", None), (6, "OUT_OF_TERM", None),
        (7, "UNREADABLE", None), (8, "UNREADABLE", None),
    ]
    first = body["items"][0]
    assert (first["tran_date"], first["merchant"], first["amount"], first["kind"]) == ("2026-03-10", "OO문구점", 35000, "APPROVAL")
    assert body["items"][6]["reason"]
    s = body["summary"]
    assert (s["total"], s["matched"], s["matched_pending"], s["unregistered"], s["unregistered_amount"], s["unreadable"]) == (8, 1, 1, 1, 12000, 2)
    assert body["text_hash"] == "0x" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def test_unpaired_cancel_matches_income_side(db_session, auth_header, fake_parser):
    # 짝 승인이 없는 취소는 입금(IN)으로 본다 — 지출 항목과는 짝이 될 수 없다
    add_entry(db_session, 2, "EXPENSE", 3000, "2026-03-19")
    body = check(auth_header, "[Web발신]\nNH 취소 03/19 OO매점 3000원").json()
    assert body["items"][0]["status"] == "UNREGISTERED"
    assert body["summary"]["unregistered_amount"] == 0  # 미등록 '승인' 합계에는 안 들어간다


def test_card_sms_does_not_touch_snapshots(db_session, auth_header, fake_parser):
    # 저장하지 않는다 — CSV 스냅샷의 짝이 그대로여야 한다
    from test_bank_reconcile import upload
    from app.models import BankTransaction, Snapshot

    demo_ledger(db_session)
    upload(auth_header)
    check(auth_header, "[Web발신]\nNH 승인 03/10 OO문구점 35000원")
    s = db_session()
    assert s.query(Snapshot).count() == 1
    assert sorted(t.matched_entry_id for t in s.query(BankTransaction) if t.matched_entry_id) == [1, 2, 3, 4]
    s.close()


def test_card_sms_errors_and_roles(db_session, auth_header, fake_parser):
    assert check(auth_header, "   \n ").status_code == 400
    assert check(auth_header, "[Web발신]\nNH 승인 03/10 A 1원", term_id=99).status_code == 404
    assert check(auth_header, "\n\n".join(["NH 승인 03/10 A 1원"] * 501)).status_code == 400
    assert client.post("/bank/card-sms/check", json={"term_id": 1, "text": "x" * 20001},
                       headers=auth_header(Role.TREASURER)).status_code == 422
    for role in (Role.AUDITOR, Role.PRESIDENT, Role.STUDENT):
        assert check(auth_header, "[Web발신]\nNH 승인 03/10 A 1원", role=role).status_code == 403


# ================================================================ 카드사 파서 — 표본 형식 (이름·카드번호는 가린 값)
from app.bank.card_sms import parse_message  # noqa: E402

KB_CREDIT_OK = "[Web발신]\nKB국민카드0*0*승인\n홍*동\n10,000원 일시불\n11/19 11:30\n가맹점명\n누적100,000원"
KB_CREDIT_CANCEL = "[Web발신]\nKB국민카드0*0*취소\n홍*동\n10,000원 일시불\n11/19 11:35\n가맹점명\n누적90,000원"
KB_CHECK_OK = "[Web발신]\nKB국민체크(0000)\n홍*동님\n11/19 11:30\n10,000원\n가맹점명 사용"
NH_OK = "[Web발신]\nNH카드0*0*승인\n홍*동\n10,000원 일시불\n11/19 11:30\n가맹점명\n누적100,000원"
NH_CHECK_OK = "[Web발신]\nNH카드0*0*승인\n홍*동\n10,000원 체크\n11/19 11:30\n가맹점명\n잔액000,000원"
NH_CANCEL = "[Web발신]\nNH카드0*0*취소\n홍*동\n10,000원 일시불\n11/19 11:35\n가맹점명\n누적90,000원"


@pytest.mark.parametrize("msg, company, kind, time", [
    (KB_CREDIT_OK, "KB", APPROVAL, "11:30:00"),
    (KB_CREDIT_CANCEL, "KB", CANCEL, "11:35:00"),
    (KB_CHECK_OK, "KB", APPROVAL, "11:30:00"),   # 체크는 첫 줄에 「승인」이 없고, 날짜가 금액보다 먼저
    (NH_OK, "NH", APPROVAL, "11:30:00"),
    (NH_CHECK_OK, "NH", APPROVAL, "11:30:00"),    # 「일시불」 대신 「체크」, 끝에 잔액 줄
    (NH_CANCEL, "NH", CANCEL, "11:35:00"),
])
def test_parse_sample_formats(msg, company, kind, time):
    s = parse_message(msg)
    assert (s.company, s.kind, s.month, s.day, s.time, s.amount, s.merchant, s.approval_no) == (
        company, kind, 11, 19, time, 10000, "가맹점명", None)


def test_parse_installment_and_long_merchant():
    msg = "[Web발신]\nKB국민카드0*0*승인\n홍*동\n1,250,000원 03개월\n03/05 09:07\n(주)OO 문구 센터\n누적1,350,000원"
    s = parse_message(msg)
    assert (s.amount, s.month, s.day, s.time, s.merchant) == (1250000, 3, 5, "09:07:00", "(주)OO 문구 센터")


def test_parse_without_web_sent_header():
    """[Web발신] 없이 복사한 문자도 읽는다 (빈 줄로 나뉜 붙여넣기)"""
    s = parse_message("NH카드0*0*승인\n홍*동\n5,000원 체크\n11/19 08:00\n편의점")
    assert (s.company, s.amount, s.merchant) == ("NH", 5000, "편의점")


@pytest.mark.parametrize("msg, why", [
    ("[Web발신]\nNH카드0*0*승인\n홍*동\n10,000원 일시불\n가맹점명", "날짜"),
    ("[Web발신]\nNH카드0*0*승인\n홍*동\n11/19 11:30\n가맹점명", "금액"),
    ("[Web발신]\nNH카드0*0*승인\n홍*동\n10,000원 일시불\n11/19 11:30\n누적100,000원", "가맹점"),
    ("[Web발신]\nNH카드0*0*승인\n홍*동\n10,000원 일시불\n13/40 11:30\n가맹점명", "올바르지"),
    ("[Web발신]\nNH카드0*0*승인\n홍*동\n0원 일시불\n11/19 11:30\n가맹점명", "금액"),
])
def test_parse_rejects_broken(msg, why):
    with pytest.raises(CardSmsError, match=why):
        parse_message(msg)


def sample(company_line, amount, mmdd, hhmm, merchant, kind_word="승인", tail="누적100,000원"):
    return f"[Web발신]\n{company_line}{kind_word}\n홍*동\n{amount:,}원 일시불\n{mmdd} {hhmm}\n{merchant}\n{tail}"


def test_card_sms_flow_with_real_formats(db_session, auth_header):
    """표본 형식 그대로 붙여 넣었을 때 — 데모 원장(3/10 문구점 35,000 확정)과 대조"""
    demo_ledger(db_session)
    text = "\n".join([
        sample("KB국민카드0*0*", 35000, "03/10", "14:03", "OO문구점"),                          # 1 확정과 짝
        "[Web발신]\nKB국민체크(0000)\n홍*동님\n03/18 08:55\n12,000원\nOO편의점 사용",           # 2 장부에 없음
        sample("NH카드0*0*", 4500, "03/19", "12:10", "OO매점"),                                 # 3 취소됨
        sample("NH카드0*0*", 4500, "03/19", "12:15", "OO매점", kind_word="취소", tail="누적0원"),  # 4 위와 상쇄
    ])
    body = check(auth_header, text).json()
    got = [(i["msg_no"], i["status"], i["entry_id"]) for i in body["items"]]
    assert got == [(1, "MATCHED", 2), (2, "UNREGISTERED", None), (3, "CANCELLED_PAIR", None), (4, "CANCELLED_PAIR", None)]
    assert body["items"][1]["merchant"] == "OO편의점"
    assert body["summary"]["unregistered_amount"] == 12000
