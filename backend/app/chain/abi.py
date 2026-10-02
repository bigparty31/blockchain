"""abi.encode 의 정적 타입 인코딩과 주소 형식 검사. entryCommit·EIP-712 도메인 해시·가짜 서명이 같이 쓴다.

정적 타입은 abi.encode 에서 모두 32바이트 칸 하나다. 범위를 벗어난 값은 ValueError 로 막는다.
"""
import re

ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]{40}")


def check_address(value: str) -> str:
    """0x + hex 40자. 대소문자(EIP-55 체크섬)는 값에 영향이 없어 둘 다 받는다."""
    if not isinstance(value, str) or not ADDRESS_RE.fullmatch(value):
        raise ValueError("주소는 0x + hex 40자여야 한다")
    return value


def uint256(value: int) -> bytes:
    if not 0 <= value < 2**256:
        raise ValueError(f"uint256 범위를 벗어났다: {value}")
    return value.to_bytes(32, "big")


def int256(value: int) -> bytes:
    if not -(2**255) <= value < 2**255:
        raise ValueError(f"int256 범위를 벗어났다: {value}")
    return value.to_bytes(32, "big", signed=True)  # 음수는 2의 보수


def address(value: str) -> bytes:
    return bytes(12) + bytes.fromhex(check_address(value)[2:])
