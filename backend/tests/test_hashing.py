"""docs/hashing_vectors.json 의 _harness 지시대로 검증한다."""
import json
import unicodedata
from datetime import date
from pathlib import Path

import pytest

from app.hashing import (
    ZERO_BYTES32,
    canonical,
    canonical_text,
    check_occurred_at,
    check_receipt_hash,
    file_hash,
    kst_midnight,
    meta_hash,
    meta_preimage,
    prepare_field,
    prepare_text,
    reason_hash,
    text_hash,
)

VECTORS = json.loads((Path(__file__).resolve().parents[2] / "docs" / "hashing_vectors.json").read_text(encoding="utf-8"))


def _meta(case):
    i = case["input"]
    counterparty, purpose = canonical(i["counterparty"]), canonical(i["purpose"])
    preimage = meta_preimage(i["amount"], counterparty, purpose, i["occurred_at"], i["receipt_hash"])
    return preimage, meta_hash(i["amount"], counterparty, purpose, i["occurred_at"], i["receipt_hash"])


@pytest.mark.parametrize("case", VECTORS["meta_hash"], ids=lambda c: c["name"])
def test_meta_hash_vectors(case):
    if case.get("input_is_nfd"):
        assert not unicodedata.is_normalized("NFC", case["input"]["counterparty"])
    preimage, digest = _meta(case)
    assert preimage.hex() == case["preimage_hex"]
    assert digest == case["expected"]


@pytest.mark.parametrize("case", VECTORS["text_hash"], ids=lambda c: c["name"])
def test_text_hash_vectors(case):
    if case.get("input_is_nfd"):
        assert not unicodedata.is_normalized("NFC", case["input"])
    assert text_hash(canonical_text(case["input"])) == case["expected"]


def test_file_hash_vectors():
    by_name = {c["name"]: c for c in VECTORS["file_hash"]}
    for case in VECTORS["file_hash"]:
        digest = file_hash(bytes.fromhex(case["content_hex"]))
        assert digest == case["expected"]
        if "must_differ_from" in case:
            assert digest != by_name[case["must_differ_from"]]["expected"]


@pytest.mark.parametrize("case", VECTORS["negative_cases"], ids=lambda c: c["name"])
def test_negative_cases(case):
    if case["kind"] == "meta_hash_pair":
        digests = []
        for entry in case["entries"]:
            preimage, digest = _meta(entry)
            assert preimage.hex() == entry["preimage_hex"]
            assert digest == entry["expected"]
            digests.append(digest)
        assert len(set(digests)) == len(digests)
    elif case["kind"] == "canonical_identity":
        assert canonical(case["input"]).encode("utf-8").hex() == case["expected_output_hex"]
    else:
        pytest.fail(f"모르는 kind: {case['kind']}")


def test_vector_file_matches_rule_version():
    from app.hashing import HASH_RULE_VERSION, US

    assert VECTORS["hash_rule_version"] == HASH_RULE_VERSION
    assert VECTORS["separator"] == US


# ---------------------------------------------------------------- 입력 검사 (§5)


@pytest.mark.parametrize("bad", ["한결\x1f문구", "한결\t문구", "\u00a0한결문구", "한결\u200b문구", "\u3000한결문구", "\ufeff한결문구"])
def test_prepare_field_rejects_invisible_and_control(bad):
    with pytest.raises(ValueError):
        prepare_field(bad, "counterparty")


def test_prepare_field_trims_normalizes_and_rejects_empty():
    nfd = unicodedata.normalize("NFD", "한결문구")
    assert prepare_field(f"  {nfd} ", "counterparty") == "한결문구"
    with pytest.raises(ValueError):
        prepare_field("   ", "purpose")


def test_prepare_text_keeps_order_so_crlf_is_not_rejected():
    assert prepare_text("영수증 금액이 다릅니다.\r\n확인 부탁드립니다.\r\n", "reason", required=True) == (
        "영수증 금액이 다릅니다.\n확인 부탁드립니다."
    )


@pytest.mark.parametrize("bad", ["사유\x0b", "사유\x1f", "사유\u200b"])
def test_prepare_text_rejects_other_control_and_invisible(bad):
    with pytest.raises(ValueError):
        prepare_text(bad, "reason", required=False)


def test_prepare_text_empty_becomes_none_or_required_error():
    assert prepare_text("  \n\t ", "reason", required=False) is None
    assert prepare_text(None, "reason", required=False) is None
    with pytest.raises(ValueError):
        prepare_text("  \n\t ", "reason", required=True)


def test_reason_hash_uses_zero_for_missing_text():
    assert reason_hash(None) == ZERO_BYTES32
    assert reason_hash("OCR 금액 불일치, 영수증 원본 확인함") == VECTORS["text_hash"][0]["expected"]


def test_meta_hash_rejects_non_int():
    from decimal import Decimal

    with pytest.raises(TypeError):
        meta_hash(Decimal("35000.00"), "한결문구", "목적", 1788793200, None)
    with pytest.raises(TypeError):
        meta_hash(True, "한결문구", "목적", 1788793200, None)


def test_kst_midnight_and_occurred_at_check():
    assert kst_midnight(date(2026, 9, 8)) == 1788793200
    assert kst_midnight(date(2026, 9, 6)) == 1788620400
    assert check_occurred_at(1788793200) == 1788793200
    for bad in (1757300000, -32400):
        with pytest.raises(ValueError):
            check_occurred_at(bad)


def test_receipt_hash_must_be_lowercase():
    assert check_receipt_hash(None) is None
    with pytest.raises(ValueError):
        check_receipt_hash("0x" + "AB" * 32)
