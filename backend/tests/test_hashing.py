import json
import os
import unicodedata
import pytest
from app.utils.hashing import (
    canonical,
    canonical_text,
    calculate_meta_hash,
    calculate_text_hash,
    calculate_file_hash,
    validate_canonical_input,
    UNIT_SEPARATOR,
)

VECTORS_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../docs/hashing_vectors.json"))


@pytest.fixture(scope="module")
def vectors():
    with open(VECTORS_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def test_meta_hash_vectors(vectors):
    for item in vectors["meta_hash"]:
        inp = item["input"]
        if item.get("input_is_nfd"):
            assert not unicodedata.is_normalized("NFC", inp["counterparty"]), f"{item['name']} should have NFD input"

        cp = canonical(inp["counterparty"])
        pp = canonical(inp["purpose"])
        
        # preimage check
        receipt_val = inp["receipt_hash"].lower() if inp["receipt_hash"] else ""
        preimage = f"{inp['amount']}{UNIT_SEPARATOR}{cp}{UNIT_SEPARATOR}{pp}{UNIT_SEPARATOR}{inp['occurred_at']}{UNIT_SEPARATOR}{receipt_val}"
        preimage_hex = preimage.encode("utf-8").hex()
        assert preimage_hex == item["preimage_hex"], f"Preimage mismatch on {item['name']}"

        res = calculate_meta_hash(
            amount=inp["amount"],
            counterparty=cp,
            purpose=pp,
            occurred_at=inp["occurred_at"],
            receipt_hash=inp["receipt_hash"],
        )
        assert res == item["expected"], f"Hash mismatch on {item['name']}"


def test_text_hash_vectors(vectors):
    for item in vectors["text_hash"]:
        inp = item["input"]
        if item.get("input_is_nfd"):
            assert not unicodedata.is_normalized("NFC", inp), f"{item['name']} should have NFD input"

        normalized = canonical_text(inp)
        res = calculate_text_hash(normalized)
        assert res == item["expected"], f"Text hash mismatch on {item['name']}"


def test_file_hash_vectors(vectors):
    results = {}
    for item in vectors["file_hash"]:
        content = bytes.fromhex(item["content_hex"])
        res = calculate_file_hash(content)
        assert res == item["expected"], f"File hash mismatch on {item['name']}"
        results[item["name"]] = res

    for item in vectors["file_hash"]:
        if "must_differ_from" in item:
            other = item["must_differ_from"]
            assert results[item["name"]] != results[other]


def test_negative_cases(vectors):
    for item in vectors["negative_cases"]:
        kind = item["kind"]
        if kind == "meta_hash_pair":
            hashes = []
            for entry in item["entries"]:
                inp = entry["input"]
                cp = canonical(inp["counterparty"])
                pp = canonical(inp["purpose"])
                h = calculate_meta_hash(
                    amount=inp["amount"],
                    counterparty=cp,
                    purpose=pp,
                    occurred_at=inp["occurred_at"],
                    receipt_hash=inp["receipt_hash"],
                )
                assert h == entry["expected"]
                hashes.append(h)
            if item.get("must_differ"):
                assert hashes[0] != hashes[1]

        elif kind == "canonical_identity":
            inp = item["input"]
            out = canonical(inp)
            out_hex = out.encode("utf-8").hex()
            assert out_hex == item["expected_output_hex"], f"Mismatch on {item['name']}"


def test_validation_rejects_forbidden_chars():
    # 탭
    with pytest.raises(ValueError):
        validate_canonical_input("한결\t문구")
    # NBSP (U+00A0)
    with pytest.raises(ValueError):
        validate_canonical_input("한결\u00a0문구")
    # 전각공백 (U+3000)
    with pytest.raises(ValueError):
        validate_canonical_input("한결\u3000문구")
    # BOM (U+FEFF)
    with pytest.raises(ValueError):
        validate_canonical_input("\ufeff한결문구")
    # 제어문자 \x1f
    with pytest.raises(ValueError):
        validate_canonical_input("한결\x1f문구")
