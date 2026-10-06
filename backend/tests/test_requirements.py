"""requirements.txt 는 ASCII 만 쓴다.

Windows 의 pip 은 이 파일을 시스템 코드 페이지(한국어 Windows 는 cp949)로 읽는다. 주석에 한글이 있으면
UnicodeDecodeError 로 설치가 멈춘다 (PR #20 2차 리뷰). 패키지를 왜 넣었는지는 커밋 메시지에 남긴다.
"""
from pathlib import Path

REQUIREMENTS = Path(__file__).resolve().parents[1] / "requirements.txt"


def test_requirements_is_ascii():
    data = REQUIREMENTS.read_bytes()
    bad = [n for n, line in enumerate(data.splitlines(), 1) if not line.isascii()]
    assert not bad, f"requirements.txt {bad}행에 ASCII 가 아닌 문자가 있다 — Windows pip(cp949)이 읽지 못한다"


def test_requirements_reads_as_cp949():
    # 한국어 Windows pip 이 실제로 쓰는 인코딩으로 읽어 본다
    REQUIREMENTS.read_text(encoding="cp949")
