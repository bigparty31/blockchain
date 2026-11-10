"""OCR 파서·판정 테스트 (PRD §6, docs/OCR.md). CLOVA 를 부르지 않고 저장된 실제 응답과 가짜 응답으로 확인한다."""
import json
from datetime import datetime
from pathlib import Path

import pytest

from app.ocr import judge, parse_clova_response
from app.ocr.parser import KST, ParsedReceipt
from app.schemas.entry import OCRStatus

SAMPLE = Path(__file__).resolve().parents[2] / "docs" / "samples" / "clova_ocr_response_example.json"


def _field(text, x0, y0, x1=None, y1=None, conf=0.999):
    x1 = x1 if x1 is not None else x0 + 10 * len(text)
    y1 = y1 if y1 is not None else y0 + 20
    return {
        "inferText": text,
        "inferConfidence": conf,
        "boundingPoly": {"vertices": [{"x": x0, "y": y0}, {"x": x1, "y": y0}, {"x": x1, "y": y1}, {"x": x0, "y": y1}]},
    }


def _response(*fields, infer_result="SUCCESS"):
    return {"images": [{"inferResult": infer_result, "fields": list(fields)}]}


def _kst(*args):
    return int(datetime(*args, tzinfo=KST).timestamp())


# --- 실제 CU 영수증 응답 ---------------------------------------------------


def test_cu_sample_extracts_amount_approval_and_time():
    parsed = parse_clova_response(json.loads(SAMPLE.read_text(encoding="utf-8")))
    assert parsed.amount == 4600
    assert parsed.approval_no == "39007018"
    assert parsed.paid_at == _kst(2026, 9, 18, 13, 22)
    assert not parsed.low_confidence


def test_cu_sample_match_and_mismatch():
    parsed = parse_clova_response(json.loads(SAMPLE.read_text(encoding="utf-8")))
    assert judge(parsed, 4600) == OCRStatus.MATCH
    assert judge(parsed, 5000) == OCRStatus.MISMATCH


# --- 파서: 좌표 기반 라벨-값 짝짓기 ----------------------------------------


def test_split_label_is_joined():
    # "*결제" "금액" 처럼 라벨이 두 덩어리로 쪼개져도 같은 줄이면 찾는다
    parsed = parse_clova_response(_response(_field("*결제", 200, 100), _field("금액", 270, 100), _field("12,000", 460, 102)))
    assert parsed.amount == 12000


def test_value_on_other_line_is_not_taken():
    # 라벨 아래 줄의 숫자는 값이 아니다
    parsed = parse_clova_response(_response(_field("결제금액:", 200, 100), _field("9,900", 460, 160)))
    assert parsed.amount is None


def test_payment_amount_beats_total():
    # 합계(할인 전)보다 결제금액을 우선한다
    parsed = parse_clova_response(_response(
        _field("합계", 200, 100), _field("10,000", 460, 100),
        _field("결제금액", 200, 140), _field("8,000", 460, 140),
    ))
    assert parsed.amount == 8000


def test_amount_attached_to_label_beats_later_total():
    # "결제금액:8,000원" 한 덩어리 뒤에 같은 줄 "합계 10,000" — 8,000 이어야 한다 (PR #36 리뷰)
    parsed = parse_clova_response(_response(_field("결제금액:8,000원", 200, 100), _field("합계", 360, 100), _field("10,000", 460, 100)))
    assert parsed.amount == 8000


def test_amount_stops_at_next_label_on_same_line():
    parsed = parse_clova_response(_response(_field("결제금액", 200, 100), _field("8,000", 300, 100), _field("합계", 360, 100), _field("10,000", 460, 100)))
    assert parsed.amount == 8000


def test_amount_with_won_suffix_is_not_a_label():
    parsed = parse_clova_response(_response(_field("결제금액", 200, 100), _field("4,600원", 460, 100)))
    assert parsed.amount == 4600


def test_approval_no_does_not_take_digits_from_next_field():
    # "승인번호:" 뒤가 "거래일자:2026-09-18" 이면 20260918 을 승인번호로 쓰지 않는다 → 판독 불가 (PR #36 리뷰)
    parsed = parse_clova_response(_response(
        _field("승인번호:", 200, 100), _field("거래일자:2026-09-18", 300, 100),
        _field("결제금액", 200, 140), _field("4,600", 460, 140),
    ))
    assert parsed.approval_label_found and parsed.approval_no is None
    assert judge(parsed, 4600) == OCRStatus.UNREADABLE


def test_approval_no_with_non_digits_is_unreadable():
    parsed = parse_clova_response(_response(_field("승인번호", 200, 100), _field("3900-7O18", 300, 100), _field("결제금액", 200, 140), _field("4,600", 460, 140)))
    assert parsed.approval_no is None
    assert judge(parsed, 4600) == OCRStatus.UNREADABLE


def test_approval_no_attached_to_label():
    parsed = parse_clova_response(_response(_field("승인번호:31008018", 200, 100), _field("7,600원", 460, 140)))
    assert parsed.approval_no == "31008018"


def test_date_and_time_in_one_token():
    parsed = parse_clova_response(_response(_field("2026.09.18 13:30:48", 200, 50)))
    assert parsed.paid_at == _kst(2026, 9, 18, 13, 30, 48)


def test_date_without_time_falls_back_to_midnight():
    parsed = parse_clova_response(_response(_field("2026-09-18", 200, 50)))
    assert parsed.paid_at == _kst(2026, 9, 18)


# --- 판정: 5상태와 우선순위 ------------------------------------------------


def _parsed(**kw):
    base = dict(amount=4600, approval_no="39007018", paid_at=_kst(2026, 9, 18, 13, 22), approval_label_found=True)
    base.update(kw)
    return ParsedReceipt(**base)


def test_no_number_when_no_approval_label():
    # 계좌이체 영수증처럼 승인번호가 원래 없음 → 정상
    assert judge(_parsed(approval_no=None, approval_label_found=False), 4600) == OCRStatus.NO_NUMBER


def test_unreadable_when_label_but_short_digits():
    parsed = parse_clova_response(_response(_field("승인번호:", 200, 100), _field("390", 300, 100), _field("결제금액", 200, 140), _field("4,600", 460, 140)))
    assert parsed.approval_label_found and parsed.approval_no is None
    assert judge(parsed, 4600) == OCRStatus.UNREADABLE


def test_unreadable_when_low_confidence():
    parsed = parse_clova_response(_response(_field("결제금액", 200, 100), _field("4,600", 460, 100, conf=0.5)))
    assert judge(parsed, 4600) == OCRStatus.UNREADABLE


def test_unreadable_when_clova_failed():
    assert judge(parse_clova_response(_response(infer_result="FAILURE")), 4600) == OCRStatus.UNREADABLE


@pytest.mark.parametrize(
    "parsed, input_amount, dup, expected",
    [
        (_parsed(), 9999, 7, OCRStatus.DUPLICATE),  # 중복이 금액 불일치보다 먼저
        (_parsed(approval_no=None, approval_label_found=False), 9999, None, OCRStatus.MISMATCH),  # 불일치가 번호 없음보다 먼저
        (_parsed(amount=None), 4600, 7, OCRStatus.UNREADABLE),  # 못 읽으면 중복도 말할 수 없음
    ],
)
def test_priority(parsed, input_amount, dup, expected):
    assert judge(parsed, input_amount, duplicate_of=dup) == expected
