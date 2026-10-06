"""저장소 루트의 .env 를 환경변수로 읽는다.

.env.example 을 .env 로 복사해 값을 채우면 서버가 그 값을 쓴다 (JWT_SECRET, DEPLOYMENTS_FILE 등).
이미 설정된 실제 환경변수가 우선한다 — 배포 환경에서 주입한 값을 .env 가 덮어쓰지 않는다.
다른 위치의 파일을 쓰려면 ENV_FILE 로 경로를 준다.

설정값을 import 시점에 읽는 모듈(app.auth.security 의 JWT_SECRET 등)보다 먼저 불려야 해서 app/__init__.py 에서 부른다.
"""
import os
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv

DEFAULT_ENV_FILE = Path(__file__).resolve().parents[2] / ".env"


def load_env_file(path: Optional[Path] = None) -> bool:
    """.env 를 읽어 환경변수에 없는 값만 채운다. 파일이 없으면 아무것도 하지 않고 False."""
    path = path or Path(os.environ.get("ENV_FILE") or DEFAULT_ENV_FILE)
    return load_dotenv(path, override=False)
