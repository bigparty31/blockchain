"""학생회비 투명성 관리 시스템 - Backend Package
"""
from app.env import load_env_file

# 설정을 import 시점에 읽는 모듈보다 먼저 .env 를 반영한다 (app/env.py)
load_env_file()
