#!/bin/sh
# 공용 개발 스택 전용. 릴레이어 키를 주지 않으면 Hardhat 공개 테스트 키를 쓴다.
set -e
if [ -z "$RELAYER_PRIVATE_KEY" ]; then
  RELAYER_PRIVATE_KEY="$(python -c 'from scripts.local_chain import RELAYER_INDEX, hardhat_key; print(hardhat_key(RELAYER_INDEX))')"
  export RELAYER_PRIVATE_KEY
fi
exec "$@"
