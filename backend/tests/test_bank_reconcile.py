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
    ("2026-02-31 14:03:11,카드출금,35000,,1215000,", "날짜"),   # 달력에 없는 날
    ("2026-03-10 24:00:00,카드출금,35000,,1215000,", "시각"),   # 범위 밖 시각
    ("2026-03-10 14:60,카드출금,35000,,1215000,", "시각"),
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


# ================================================================ 학생 홈 카드 (GET /snapshots/latest)


def latest(auth_header, role=Role.STUDENT, **params):
    return client.get("/snapshots/latest", params=params, headers=auth_header(role))


def test_student_sees_only_unregistered_withdrawals(db_session, auth_header):
    demo_ledger(db_session)
    report = upload(auth_header).json()
    res = latest(auth_header, term_id=TERM)
    assert res.status_code == 200
    body = res.json()
    # 앱(SnapshotModel.fromJson)이 읽는 키만. file_hash·거래 원문·반대 방향 대조는 학생에게 안 보낸다
    assert set(body) == {"id", "term_id", "bank_balance", "snapshot_at", "tx_hash", "unrecorded"}
    assert (body["id"], body["term_id"], body["bank_balance"], body["tx_hash"]) == (report["snapshot_id"], TERM, 1171000, None)
    assert isinstance(body["snapshot_at"], int)
    row = next(t for t in report["transactions"] if t["status"] == "UNREGISTERED")
    when = datetime.strptime(f"{row['tran_date']} {row['tran_time']}", "%Y-%m-%d %H:%M:%S").replace(tzinfo=KST)
    assert body["unrecorded"] == [{"amount": 12000, "counterparty": row["description"], "occurred_at": int(when.timestamp())}]


def test_unregistered_deposit_not_shown(db_session, auth_header):
    # 원장이 비면 입금 10,000·50,000 도 미등록이지만, 학생 카드는 '장부 없이 나간 돈'만 보인다
    upload(auth_header)
    amounts = [u["amount"] for u in latest(auth_header, term_id=TERM).json()["unrecorded"]]
    assert sorted(amounts) == [12000, 35000, 82000]


def test_latest_follows_newest_upload_and_rematch(db_session, auth_header):
    demo_ledger(db_session)
    upload(auth_header)
    newer = upload(auth_header, raw=KB).json()["snapshot_id"]
    assert latest(auth_header, term_id=TERM).json()["id"] == newer
    add_entry(db_session, 5, "EXPENSE", 12000, "2026-03-18")
    client.post(f"/bank/snapshots/{newer}/rematch", headers=auth_header(Role.TREASURER))
    assert latest(auth_header, term_id=TERM).json()["unrecorded"] == []


def test_latest_defaults_to_current_term(db_session, auth_header):
    upload(auth_header, term_id=TERM)
    other = upload(auth_header, term_id=2).json()["snapshot_id"]
    # 2026-2학기(9/1~12/20)가 진행 중이거나, 끝났어도 가장 최근에 시작한 학기다
    assert latest(auth_header).json()["id"] == other


def test_latest_survives_bad_stored_dates(db_session, auth_header):
    # 업로드 검증 전에 저장된 값이 달력에 없어도 카드가 500 이 되지 않는다 (#117 리뷰)
    upload(auth_header)
    with db_session() as s:
        rows = s.query(BankTransaction).filter(BankTransaction.direction == "OUT").order_by(BankTransaction.id).all()
        rows[0].tran_time = "24:00:00"   # 시각만 틀림 → 그날 자정
        rows[1].tran_date = "2026-02-31"  # 날짜가 틀림 → 업로드 시각
        bad_time_date, bad_date_amount = rows[0].tran_date, rows[1].amount
        s.commit()
    res = latest(auth_header, term_id=TERM)
    assert res.status_code == 200
    body = res.json()
    by_amount = {u["amount"]: u["occurred_at"] for u in body["unrecorded"]}
    assert by_amount[bad_date_amount] == body["snapshot_at"]
    midnight = int(datetime.strptime(bad_time_date, "%Y-%m-%d").replace(tzinfo=KST).timestamp())
    assert midnight in by_amount.values()


def test_latest_404_and_auth(db_session, auth_header):
    assert latest(auth_header, term_id=TERM).status_code == 404
    assert client.get("/snapshots/latest", params={"term_id": TERM}).status_code == 401
    upload(auth_header)
    for role in (Role.STUDENT, Role.TREASURER, Role.AUDITOR, Role.PRESIDENT):
        assert latest(auth_header, role=role, term_id=TERM).status_code == 200


def test_student_server_serves_latest(db_session, auth_header):
    from app.main_student import app as student_app
    upload(auth_header)
    student_app.dependency_overrides[get_db] = app.dependency_overrides[get_db]
    try:
        res = TestClient(student_app).get("/snapshots/latest", params={"term_id": TERM}, headers=auth_header(Role.STUDENT))
    finally:
        student_app.dependency_overrides.pop(get_db, None)
    assert res.status_code == 200 and len(res.json()["unrecorded"]) == 3


# ================================================================ 잔액 차이 학생 알림


class TopicRecorder:
    def __init__(self):
        self.topics = []

    def send_to_topic(self, topic, message):
        self.topics.append((topic, message.body))

    def send_to_tokens(self, tokens, message):
        return []


def test_mismatch_pushes_students(db_session, auth_header):
    from app.services import push
    demo_ledger(db_session)  # 장부 -57,000 vs 계좌 1,171,000
    upload(auth_header)
    sender = TopicRecorder()
    push.drain(db_session, sender)
    assert sender.topics == [("students_20261", "장부와 계좌 잔액이 다릅니다.")]


def test_no_push_when_balanced(db_session, auth_header):
    from app.services import push
    demo_ledger(db_session)
    add_entry(db_session, 5, "EXPENSE", 12000, "2026-03-18")
    add_entry(db_session, 6, "INCOME", 1240000, "2026-02-28")  # 학기 전 이월금 — 장부 1,171,000 = 계좌
    upload(auth_header)
    sender = TopicRecorder()
    push.drain(db_session, sender)
    assert sender.topics == []


# ================================================================ 파일 순서는 잔액으로 정한다 (#107)

DAY_HEADER = "거래일자,적요,출금액,입금액,거래후잔액"


def csv_of(*lines, header=DAY_HEADER):
    return ("\n".join([header, *lines]) + "\n").encode("utf-8")


# 같은 날 1,000 입금 → 200 출금 → 100 출금. 시각이 없어 날짜로는 순서를 알 수 없다
SAME_DAY_OLDEST_FIRST = ["2026-03-05,최초,0,1000,1000", "2026-03-05,중간,200,0,800", "2026-03-05,최근,100,0,700"]


def test_same_day_newest_first_file_uses_last_balance(db_session, auth_header):
    """이슈 재현: 최신순 하루치 파일에서 가장 오래된 잔액(1,000)이 계좌 잔액으로 저장되던 문제"""
    rep = upload(auth_header, raw=csv_of(*reversed(SAME_DAY_OLDEST_FIRST))).json()
    assert rep["bank_balance"] == 700
    assert [t["description"] for t in rep["transactions"]] == ["최초", "중간", "최근"]  # 시간순 저장


def test_same_day_oldest_first_file_kept(db_session, auth_header):
    rep = upload(auth_header, raw=csv_of(*SAME_DAY_OLDEST_FIRST)).json()
    assert rep["bank_balance"] == 700
    assert [t["description"] for t in rep["transactions"]] == ["최초", "중간", "최근"]


def test_order_undecidable_is_rejected(db_session, auth_header):
    """+100 뒤 −100 은 두 방향 다 잔액이 이어진다. 같은 시각이면 어느 잔액이 최종인지 몰라 보완을 요구한다"""
    res = upload(auth_header, raw=csv_of("2026-03-05,입금,0,100,1100", "2026-03-05,출금,100,0,1000"))
    assert res.status_code == 400
    assert "순서" in res.json()["detail"]
    with db_session() as s:
        assert s.query(Snapshot).count() == 0


def test_order_undecidable_by_balance_uses_time(db_session, auth_header):
    """두 방향 다 잔액이 이어져도 시각이 다르면 시각으로 정한다 — 최신순 파일"""
    header = "거래일시,적요,출금액,입금액,거래후잔액"
    rep = upload(auth_header, raw=csv_of("2026-03-05 15:00:00,출금,100,0,1000", "2026-03-05 09:00:00,입금,0,100,1100",
                                         header=header)).json()
    assert rep["bank_balance"] == 1000


def test_broken_balance_chain_is_rejected(db_session, auth_header):
    """잔액이 어느 방향으로도 이어지지 않으면 (다른 계좌가 섞였거나 줄을 고친 파일) 잔액을 믿을 수 없다"""
    res = upload(auth_header, raw=csv_of("2026-03-05,입금,0,1000,1000", "2026-03-06,출금,200,0,900"))
    assert res.status_code == 400
    assert "거래후잔액" in res.json()["detail"]


def test_dates_against_balance_order_are_rejected(db_session, auth_header):
    """잔액으로는 시간순인데 날짜가 거꾸로 가면 고친 파일이다"""
    res = upload(auth_header, raw=csv_of("2026-03-06,입금,0,1000,1000", "2026-03-05,출금,200,0,800"))
    assert res.status_code == 400


# ================================================================ 정정 뒤의 보고서 (#100)


def correct(Session, id, original_id, amount, date, status="CONFIRMED"):
    add_entry(Session, id, "INCOME" if original_id in (1, 4) else "EXPENSE", amount, date, status=status,
              corrects_entry_id=original_id, correction_reason="INPUT_ERROR")


def test_report_unmatches_after_correction_changes_net_amount(db_session, auth_header):
    """이슈 재현: 50,000 입금과 짝지은 수입을 −20,000 정정해 순금액이 30,000 이 되면 더 이상 짝이 아니다"""
    demo_ledger(db_session)
    snap_id = upload(auth_header).json()["snapshot_id"]
    correct(db_session, 9, 4, -20000, "2026-03-16")

    rep = client.get(f"/bank/snapshots/{snap_id}", headers=auth_header(Role.AUDITOR)).json()
    assert (50000, "UNREGISTERED", None) in statuses(rep)
    assert [(u["entry_id"], u["amount"]) for u in rep["unbacked_entries"]] == [(4, 30000)]
    s = rep["summary"]
    assert (s["matched"], s["unregistered"], s["unregistered_in_amount"], s["unbacked"]) == (3, 2, 50000, 1)

    # 재대조해도 같은 판정 — 보고서가 재대조 전후로 다르게 말하지 않는다
    after = client.post(f"/bank/snapshots/{snap_id}/rematch", headers=auth_header(Role.TREASURER)).json()
    assert after["summary"] == rep["summary"]
    assert after["transactions"] == rep["transactions"]


def test_report_keeps_match_while_correction_pending(db_session, auth_header):
    """확정 전 정정은 순금액에 넣지 않는다 (_Ledger) — 짝도 그대로"""
    demo_ledger(db_session)
    snap_id = upload(auth_header).json()["snapshot_id"]
    correct(db_session, 9, 4, -20000, "2026-03-16", status="PENDING")
    rep = client.get(f"/bank/snapshots/{snap_id}", headers=auth_header(Role.AUDITOR)).json()
    assert (50000, "MATCHED", 4) in statuses(rep)


def test_student_card_reflects_correction(db_session, auth_header):
    """학생 계좌 대조 카드(GET /snapshots/latest)도 같은 보고서를 쓴다 — 정정으로 짝이 풀린 출금은 미등록 출금으로 보인다"""
    demo_ledger(db_session)
    upload(auth_header)
    correct(db_session, 9, 3, -2000, "2026-03-13")  # 82,000 출금과 짝이던 지출이 80,000 이 됨
    res = client.get("/snapshots/latest", params={"term_id": TERM}, headers=auth_header(Role.STUDENT))
    assert res.status_code == 200
    assert sorted(t["amount"] for t in res.json()["unrecorded"]) == [12000, 82000]
