#!/usr/bin/env bash
# 공용 개발 스택을 처음 상태로 되돌린다: 체인·DB 삭제 → 배포 → 마이그레이션 → 시드 → 체인 예산 발행.
# VM 을 재시작해 체인이 지워졌을 때도 이것으로 복구한다. DB 내용도 함께 지워진다.
#   --yes         확인 없이 진행
#   --no-budgets  체인 예산 발행을 건너뛴다. 예산 편성 화면을 시험할 때 쓴다
set -euo pipefail
cd "$(dirname "$0")/.."

assume_yes=0
issue_budgets=1
for arg in "$@"; do
  case "$arg" in
    --yes) assume_yes=1 ;;
    --no-budgets) issue_budgets=0 ;;
    *) echo "알 수 없는 옵션: $arg" >&2; exit 2 ;;
  esac
done

if [ "$assume_yes" -ne 1 ]; then
  read -r -p "체인과 DB 를 모두 지웁니다. 계속할까요? [y/N] " answer
  [ "$answer" = "y" ] || { echo "취소했습니다."; exit 1; }
fi

if [ ! -f .env ]; then
  umask 077
  {
    echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
    echo "JWT_SECRET=$(openssl rand -hex 32)"
    if command -v tailscale >/dev/null 2>&1; then
      echo "BIND_ADDR=$(tailscale ip -4 | head -1)"
    fi
  } > .env
  echo ".env 를 새로 만들었습니다."
fi

# .env 에 값이 있는가 (빈 값은 없는 것으로 본다)
has_env() { grep -Eq "^$1=.+" .env; }
# 빈 줄로 남은 항목을 지우고 새 값을 붙인다
put_env() { sed -i "/^$1=\$/d" .env; printf '%s=%s\n' "$1" "$2" >> .env; echo ".env 에 $1 을 추가했습니다."; }

# 릴레이어: 개발 체인(Hardhat)의 #4 계정. 롤이 없고 잔액이 있다 (backend/scripts/local_chain.py RELAYER_INDEX).
# 키는 Hardhat 기본 니모닉이라 공개된 값이다. 이 체인 밖(Amoy 등)에서는 쓰지 않는다
if ! has_env RELAYER_PRIVATE_KEY; then
  put_env RELAYER_PRIVATE_KEY 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
fi

docker compose build api

# 학생 지갑 니모닉: 새로 만든다. Hardhat 기본 니모닉은 학생 주소가 임원 주소와 겹쳐 쓰지 않는다 (docs/SERVER_ENV.md 6절).
# 한번 만들면 바꾸지 않는다 — 바꾸면 학생 주소가 모두 바뀐다. 초기화해도 .env 의 값은 그대로 둔다
if ! has_env STUDENT_WALLET_MNEMONIC; then
  mnemonic=$(docker compose run --rm --no-deps -T api python -c \
    "from eth_account import Account; Account.enable_unaudited_hdwallet_features(); print(Account.create_with_mnemonic()[1])")
  [ "$(echo "$mnemonic" | wc -w)" -eq 12 ] || { echo "학생 지갑 니모닉을 만들지 못했습니다." >&2; exit 1; }
  put_env STUDENT_WALLET_MNEMONIC "\"$mnemonic\""
fi

docker compose down -v --remove-orphans
docker compose up -d --build --wait db chain
docker compose exec -T chain npx hardhat run scripts/deploy.ts --network localhost
init_command="alembic upgrade head && python -m scripts.seed"
if [ "$issue_budgets" -eq 1 ]; then
  init_command="$init_command && python -m scripts.issue_seed_budgets"
fi
docker compose run --rm api sh -c "$init_command"
docker compose up -d api
echo "완료. 상태 확인: docker compose ps"
