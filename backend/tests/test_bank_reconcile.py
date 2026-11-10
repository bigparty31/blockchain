"""계좌 대조 테스트 — PRD v0.15 §4.6, docs/BANK_CSV.md.

파서·매처는 DB 없이, API 는 임시 SQLite 로 확인한다. 샘플 파일은 docs/samples 의 팀 공용 데모 세트를 쓴다.
"""
import base64
import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.auth import users as seed
from app.bank import BankCsvError, BankRow, Candidate, decode, match, parse_bank_csv
from app.database import get_db
from app.main import app
from app.models import Base, BankTransaction, Entry, Snapshot, Term, User
from app.schemas.auth import Role

client = TestClient(app)

SAMPLES = Path(__file__).resolve().parents[2] / "docs" / "samples"
NH = (SAMPLES / "nh_sample.csv").read_bytes()
KB = (SAMPLES / "kb_sample.csv").read_bytes()
KST = timezone(timedelta(hours=9))
TERM = 1


def kst(date: str) -> int:
    """'2026-03-05' → KST 자정 Unix 초 (Entry.occurred_at 규칙)."""
    return int(datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=KST).timestamp())


# ================================================================ 파서


def test_parse_nh_sample():
    rows = parse_bank_csv(NH)
    assert len(rows) == 5
    r = rows[1]
    assert (r.tran_date, r.tran_time, r.direction, r.amount, r.balance_after) == ("2026-03-10", "14:03:11", "OUT", 35000, 1215000)
    assert r.description == "카드출금 OO문구점"  # 적요 + 거래점
    assert rows[0].direction == "IN" and rows[0].amount == 10000


def test_nh_and_kb_give_same_transactions():
    # 은행 형식만 다르고 같은 5건이다 (docs/samples). 적요 문구만 다르다
    key = lambda r: (r.tran_date, r.tran_time, r.direction, r.amount, r.balance_after)
    assert [key(r) for r in parse_bank_csv(NH)] == [key(r) for r in parse_bank_csv(KB)]


def test_parse_matches_normalized_sample():
    import csv, io
    expected = list(csv.DictReader(io.StringIO((SAMPLES / "normalized_sample.csv").read_text(encoding="utf-8"))))
    rows = parse_bank_csv(NH)
    for r, e in zip(rows, expected):
        assert (r.tran_date, r.tran_time, r.direction, str(r.amount), str(r.balance_after)) == (
            e["tran_date"], e["tran_time"], e["direction"], e["amount"], e["balance_after"])


def test_cp949_file():
    raw = NH.decode("utf-8").encode("cp949")
    assert [r.amount for r in parse_bank_csv(raw)] == [r.amount for r in parse_bank_csv(NH)]


def test_utf8_bom_file():
    assert len(parse_bank_csv(b"\xef\xbb\xbf" + NH)) == 5


def test_decode_prefers_utf8():
    # UTF-8 한글을 CP949 로 먼저 읽으면 깨진 글자가 나올 수 있다. UTF-8 로 읽혀야 한다
    assert decode("거래일시".encode("utf-8")) == "거래일시"


def test_undecodable_file():
    with pytest.raises(BankCsvError):
        parse_bank_csv(b"\xff\xfe\xff\x00\x81")


def test_preamble_lines_and_alias_headers():
    raw = (
        "농협 거래내역 조회\n"
        "계좌번호,301-0000-0000-00\n"
        "조회기간,2026.03.01~2026.03.31\n"
        "\n"
        "거래일자,거래시간,내용,찾으신금액,맡기신금액,잔액\n"
        '2026.03.10,1403,카드출금,"35,000",0,"1,215,000"\n'
        "20260311,09:00,이체입금,-,5000원,1220000\n"
        ",,합계,35000,5000,\n"
    ).encode("utf-8")
    rows = parse_bank_csv(raw)
    assert [(r.tran_date, r.tran_time, r.direction, r.amount, r.balance_after) for r in rows] == [
        ("2026-03-10", "14:03:00", "OUT", 35000, 1215000),
        ("2026-03-11", "09:00:00", "IN", 5000, 1220000),
    ]


@pytest.mark.parametrize("line,msg", [
    ("2026-03-10 14:03:11,카드출금,35000,1000,1215000,", "하나만"),   # 출금·입금 둘 다
    ("2026-03-10 14:03:11,카드출금,,,1215000,", "하나만"),            # 둘 다 없음
    ("2026-03-10 14:03:11,카드출금,3.5만,,1215000,", "숫자"),
    ("2026-13-10 14:03:11,카드출금,35000,,1215000,", "날짜"),
    ("어제,카드출금,35000,,1215000,", "날짜"),
    ("2026-03-10 오후2시,카드출금,35000,,1215000,", "시각"),
])
def test_bad_rows(line, msg):
    raw = ("거래일시,적요,출금액,입금액,거래후잔액,거래점\n" + line + "\n").encode("utf-8")
    with pytest.raises(BankCsvError, match=msg):
        parse_bank_csv(raw)


def test_no_header_or_no_rows():
    with pytest.raises(BankCsvError, match="헤더"):
        parse_bank_csv("a,b,c\n1,2,3\n".encode("utf-8"))
    with pytest.raises(BankCsvError, match="한 건도"):
        parse_bank_csv("거래일시,적요,출금액,입금액,거래후잔액\n".encode("utf-8"))


# ================================================================ 매처


def row(n, d, amt, direction="OUT"):
    return BankRow(n, d, None, "x", direction, amt, 0)


def cand(i, d, amt, direction="OUT", confirmed=True):
    return Candidate(i, direction, amt, d, confirmed)


def test_match_consumes_one_to_one():
    # 같은 날 같은 금액 2건 vs 원장 1건 → 하나만 짝, 나머지는 미등록
    rows = [row(1, "2026-03-10", 5000), row(2, "2026-03-10", 5000)]
    got = match(rows, [cand(7, "2026-03-10", 5000)])
    assert [c.entry_id if c else None for c in got] == [7, None]
    # 원장도 2건이면 둘 다 맞는다
    got = match(rows, [cand(7, "2026-03-10", 5000), cand(8, "2026-03-10", 5000)])
    assert [c.entry_id for c in got] == [7, 8]


def test_match_needs_same_direction_amount_date():
    rows = [row(1, "2026-03-10", 5000)]
    for c in (cand(1, "2026-03-10", 5000, direction="IN"), cand(2, "2026-03-11", 5000), cand(3, "2026-03-10", 5001)):
        assert match(rows, [c]) == [None]


def test_match_prefers_confirmed_over_pending():
    got = match([row(1, "2026-03-10", 5000)], [cand(1, "2026-03-10", 5000, confirmed=False), cand(9, "2026-03-10", 5000)])
    assert got[0].entry_id == 9


# ================================================================ API


@pytest.fixture
def db_session(tmp_path):
    engine = create_engine(f"sqlite:///{tmp_path / 'bank.db'}", connect_args={"check_same_thread": False})
    Session = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    Base.metadata.create_all(bind=engine)
    db = Session()
    for u in seed.SEED_USERS:
        db.add(User(id=u.id, student_no=u.student_no, name=u.name, role=u.role.value, password_hash=u.password_hash,
                    wallet_index=u.wallet_index, wallet_address=u.wallet_address.lower() if u.wallet_address else None))
    db.add(Term(id=TERM, term_code=20261, name="2026-1학기",
                started_at=datetime(2026, 3, 1, tzinfo=timezone.utc), ended_at=datetime(2026, 6, 30, tzinfo=timezone.utc)))
    db.add(Term(id=2, term_code=20262, name="2026-2학기",
                started_at=datetime(2026, 9, 1, tzinfo=timezone.utc), ended_at=datetime(2026, 12, 20, tzinfo=timezone.utc)))
    db.commit()
    db.close()

    def override():
        s = Session()
        try:
            yield s
        finally:
            s.close()

    app.dependency_overrides[get_db] = override
    yield Session
    app.dependency_overrides.pop(get_db, None)
    engine.dispose()


def add_entry(Session, id, kind, amount, date, status="CONFIRMED", term=TERM, **kw):
    s = Session()
    s.add(Entry(id=id, term_id=term, kind=kind, amount=amount, counterparty=kw.pop("counterparty", "거래처"),
                purpose=kw.pop("purpose", "목적"), occurred_at=kst(date), status=status, created_by=2,
                approved_by=3 if status == "CONFIRMED" else None,
                reject_reason="반려" if status == "REJECTED" else None, **kw))
    s.commit()
    s.close()


def demo_ledger(Session):
    # docs/samples/ledger_dummy_entries.csv 와 같은 4건 — 3/18 편의점 12,000 은 원장에 없다
    add_entry(Session, 1, "INCOME", 10000, "2026-03-05")
    add_entry(Session, 2, "EXPENSE", 35000, "2026-03-10", counterparty="OO문구점")
    add_entry(Session, 3, "EXPENSE", 82000, "2026-03-12", counterparty="OO식당")
    add_entry(Session, 4, "INCOME", 50000, "2026-03-15")


def upload(auth_header, raw=NH, role=Role.TREASURER, term_id=TERM, **extra):
    body = {"term_id": term_id, "file_base64": base64.b64encode(raw).decode(), **extra}
    return client.post("/bank/snapshots", json=body, headers=auth_header(role))


def statuses(report):
    return [(t["amount"], t["status"], t["entry_id"]) for t in report["transactions"]]


def test_demo_finds_the_one_unregistered(db_session, auth_header):
    demo_ledger(db_session)
    res = upload(auth_header)
    assert res.status_code == 201
    rep = res.json()
    assert statuses(rep) == [
        (10000, "MATCHED", 1), (35000, "MATCHED", 2), (82000, "MATCHED", 3), (50000, "MATCHED", 4),
        (12000, "UNREGISTERED", None),
    ]
    s = rep["summary"]
    assert (s["total"], s["matched"], s["unregistered"], s["unregistered_out_amount"], s["unbacked"]) == (5, 4, 1, 12000, 0)
    assert rep["bank_balance"] == 1171000  # 마지막 거래의 거래후잔액
    assert (rep["period_start"], rep["period_end"]) == ("2026-03-05", "2026-03-18")
    assert rep["file_hash"] == "0x" + hashlib.sha256(NH).hexdigest()
    assert rep["superseded"] is False


def test_saved_to_db(db_session, auth_header):
    demo_ledger(db_session)
    upload(auth_header)
    s = db_session()
    snap = s.query(Snapshot).one()
    assert (snap.term_id, snap.bank_balance, snap.uploaded_by, snap.tx_hash) == (TERM, 1171000, 2, None)
    assert s.query(BankTransaction).count() == 5
    assert sorted(t.matched_entry_id for t in s.query(BankTransaction) if t.matched_entry_id) == [1, 2, 3, 4]
    # 원장에 자동 반영하지 않는다 (PRD §4.6)
    assert s.query(Entry).count() == 4
    s.close()


def test_newest_first_file_balance(db_session, auth_header):
    lines = NH.decode("utf-8").strip().split("\n")
    reversed_file = ("\n".join([lines[0]] + lines[1:][::-1]) + "\n").encode("utf-8")
    rep = upload(auth_header, raw=reversed_file).json()
    assert rep["bank_balance"] == 1171000
    assert [t["tran_date"] for t in rep["transactions"]][0] == "2026-03-05"  # 시간순 저장


@pytest.mark.parametrize("status_", ["BLOCKED", "REJECTED", None])
def test_excluded_statuses_stay_unregistered(db_session, auth_header, status_):
    # 예산 초과로 확정 못 한(BLOCKED) 지출에 대응하는 출금은 미등록으로 드러나야 한다
    demo_ledger(db_session)
    add_entry(db_session, 5, "EXPENSE", 12000, "2026-03-18", status=status_)
    rep = upload(auth_header).json()
    assert statuses(rep)[-1] == (12000, "UNREGISTERED", None)


def test_pending_match_marked(db_session, auth_header):
    demo_ledger(db_session)
    add_entry(db_session, 5, "EXPENSE", 12000, "2026-03-18", status="PENDING")
    rep = upload(auth_header).json()
    assert statuses(rep)[-1] == (12000, "MATCHED_PENDING", 5)
    assert rep["summary"]["matched_pending"] == 1


def test_unbacked_entry_within_period_only(db_session, auth_header):
    demo_ledger(db_session)
    add_entry(db_session, 5, "EXPENSE", 99000, "2026-03-11", counterparty="가짜거래처")  # 기간 안, 계좌에 없음
    add_entry(db_session, 6, "EXPENSE", 7000, "2026-04-02")  # 기간 밖 — 이 파일로 판단 못 함
    rep = upload(auth_header).json()
    assert [(u["entry_id"], u["amount"], u["counterparty"]) for u in rep["unbacked_entries"]] == [(5, 99000, "가짜거래처")]


def test_input_error_correction_uses_net_amount(db_session, auth_header):
    # 35,000 을 40,000 으로 잘못 넣고 -5,000 정정 → 계좌 35,000 과 짝
    add_entry(db_session, 2, "EXPENSE", 40000, "2026-03-10")
    add_entry(db_session, 9, "EXPENSE", -5000, "2026-03-10", corrects_entry_id=2, correction_reason="INPUT_ERROR")
    rep = upload(auth_header).json()
    assert (35000, "MATCHED", 2) in statuses(rep)
    assert rep["unbacked_entries"] == []


def test_pending_correction_not_applied(db_session, auth_header):
    add_entry(db_session, 2, "EXPENSE", 40000, "2026-03-10")
    add_entry(db_session, 9, "EXPENSE", -5000, "2026-03-10", status="PENDING",
              corrects_entry_id=2, correction_reason="INPUT_ERROR")
    rep = upload(auth_header).json()
    assert (35000, "UNREGISTERED", None) in statuses(rep)
    assert [u["amount"] for u in rep["unbacked_entries"]] == [40000]


def test_fully_refunded_entry_not_candidate(db_session, auth_header):
    add_entry(db_session, 2, "EXPENSE", 35000, "2026-03-10")
    add_entry(db_session, 9, "EXPENSE", -35000, "2026-03-11", corrects_entry_id=2, correction_reason="REFUND")
    rep = upload(auth_header).json()
    assert (35000, "UNREGISTERED", None) in statuses(rep)
    assert rep["unbacked_entries"] == []


def test_other_term_entries_ignored(db_session, auth_header):
    add_entry(db_session, 2, "EXPENSE", 35000, "2026-03-10", term=2)
    assert (35000, "UNREGISTERED", None) in statuses(upload(auth_header).json())


def test_rematch_after_registering(db_session, auth_header):
    demo_ledger(db_session)
    snap_id = upload(auth_header).json()["snapshot_id"]
    # 같은 파일 재업로드는 막힌다
    assert upload(auth_header).status_code == 409
    add_entry(db_session, 5, "EXPENSE", 12000, "2026-03-18")
    res = client.post(f"/bank/snapshots/{snap_id}/rematch", headers=auth_header(Role.TREASURER))
    assert res.status_code == 200
    assert res.json()["summary"]["unregistered"] == 0


def test_report_reflects_later_rejection(db_session, auth_header):
    demo_ledger(db_session)
    add_entry(db_session, 5, "EXPENSE", 12000, "2026-03-18", status="PENDING")
    snap_id = upload(auth_header).json()["snapshot_id"]
    s = db_session()
    e = s.get(Entry, 5)
    e.status, e.rejected_by, e.reject_reason = "REJECTED", 3, "영수증 불일치"
    s.commit()
    s.close()
    rep = client.get(f"/bank/snapshots/{snap_id}", headers=auth_header(Role.AUDITOR)).json()
    assert statuses(rep)[-1] == (12000, "UNREGISTERED", None)


def test_new_upload_supersedes_and_moves_matches(db_session, auth_header):
    demo_ledger(db_session)
    first = upload(auth_header).json()["snapshot_id"]
    # 한 달치를 더 받은 누적 파일 — 앞 5건 + 1건
    more = NH + "2026-03-20 11:00:00,카드출금,3000,,1168000,OO매점\n".encode("utf-8")
    second = upload(auth_header, raw=more)
    assert second.status_code == 201
    assert second.json()["summary"]["matched"] == 4

    old = client.get(f"/bank/snapshots/{first}", headers=auth_header(Role.AUDITOR)).json()
    assert old["superseded"] is True and old["summary"] is None
    assert all(t["status"] is None for t in old["transactions"])
    # 이전 스냅샷은 재대조할 수 없다
    assert client.post(f"/bank/snapshots/{first}/rematch", headers=auth_header(Role.TREASURER)).status_code == 409

    listed = client.get("/bank/snapshots", params={"term_id": TERM}, headers=auth_header(Role.PRESIDENT)).json()
    assert [(x["id"], x["superseded"]) for x in listed] == [(second.json()["snapshot_id"], False), (first, True)]


def test_same_file_other_term_allowed(db_session, auth_header):
    assert upload(auth_header).status_code == 201
    assert upload(auth_header, term_id=2).status_code == 201


def test_file_hash_check(db_session, auth_header):
    good = "0x" + hashlib.sha256(NH).hexdigest()
    assert upload(auth_header, file_hash="0x" + "0" * 64).status_code == 400
    assert upload(auth_header, file_hash=good.upper().replace("0X", "0x")).status_code == 422  # 대문자 hex 거부
    assert upload(auth_header, file_hash=good).status_code == 201


@pytest.mark.parametrize("body,code", [
    ({"file_base64": "!!!"}, 400),
    ({"file_base64": ""}, 400),
    ({"file_base64": base64.b64encode(b"a,b\n1,2\n").decode()}, 400),
    ({"file_base64": base64.b64encode(b"x" * (2 * 1024 * 1024 + 1)).decode()}, 413),
    ({"term_id": 99}, 404),
])
def test_bad_uploads(db_session, auth_header, body, code):
    payload = {"term_id": TERM, "file_base64": base64.b64encode(NH).decode(), **body}
    assert client.post("/bank/snapshots", json=payload, headers=auth_header(Role.TREASURER)).status_code == code
    s = db_session()
    assert s.query(Snapshot).count() == 0
    s.close()


@pytest.mark.parametrize("role", [Role.AUDITOR, Role.PRESIDENT, Role.STUDENT])
def test_only_treasurer_uploads(db_session, auth_header, role):
    assert upload(auth_header, role=role).status_code == 403


def test_council_reads_student_cannot(db_session, auth_header):
    snap_id = upload(auth_header).json()["snapshot_id"]
    for role in (Role.TREASURER, Role.AUDITOR, Role.PRESIDENT):
        assert client.get(f"/bank/snapshots/{snap_id}", headers=auth_header(role)).status_code == 200
    assert client.get(f"/bank/snapshots/{snap_id}", headers=auth_header(Role.STUDENT)).status_code == 403
    assert client.get("/bank/snapshots", params={"term_id": TERM}, headers=auth_header(Role.STUDENT)).status_code == 403
    assert client.get("/bank/snapshots/999", headers=auth_header(Role.AUDITOR)).status_code == 404
