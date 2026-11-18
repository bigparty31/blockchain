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

# 값이 있는가는 .env 를 직접 읽지 않고 compose 가 api 컨테이너에 넘기는 값으로 판단한다.
# api 는 docker-compose.yml 의 ${NAME:-} 로 값을 받으므로, compose 의 .env 해석(따옴표·`export`·주석·중복 키는
# 마지막 값)이 그대로 백엔드가 보는 값이다. 같은 규칙을 셸로 다시 짜면 어긋난다 (#101 Codex 1·2차)
# 컨테이너를 못 띄운 것을 "값 없음"으로 읽으면 멀쩡한 값을 덮어쓰므로, 읽기 실패는 멈춘다
# (${NAME:-} 라 변수는 늘 설정돼 있어 printenv 의 실패는 곧 실행 실패다)
has_env() {
  local value
  value=$(docker compose run --rm --no-deps -T api printenv "$1") || {
    echo "api 컨테이너에서 $1 값을 읽지 못했습니다. .env 와 docker 상태를 확인하세요." >&2
    exit 1
  }
  [ -n "$(printf '%s' "$value" | tr -d '[:space:]')" ]
}
# 그 이름의 기존 줄은 지우지 않고 주석으로 돌린 뒤 새 값을 붙인다. 비어 보였는데 실은 값이 있던 줄이 있어도 잃지 않는다
put_env() {
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=" .env; then
    sed -i -E "s/^([[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=.*)$/# dev-stack-reset 가 비활성화 (compose 기준 최종 값이 비어 있었음): \1/" .env
    echo ".env 의 기존 $1 줄은 지우지 않고 주석으로 돌렸습니다."
  fi
  # 마지막 줄이 줄바꿈 없이 끝나면 새 값이 앞줄에 붙으므로 줄바꿈을 먼저 넣는다
  if [ -s .env ] && [ -n "$(tail -c1 .env)" ]; then echo >> .env; fi
  printf '%s=%s\n' "$1" "$2" >> .env
  echo ".env 에 $1 을 추가했습니다."
}

# 값 판단에 api 이미지가 필요하므로 먼저 빌드한다
docker compose build api

# 릴레이어: 개발 체인(Hardhat)의 #4 계정. 롤이 없고 잔액이 있다 (backend/scripts/local_chain.py RELAYER_INDEX).
# 키는 Hardhat 기본 니모닉이라 공개된 값이다. 이 체인 밖(Amoy 등)에서는 쓰지 않는다
if ! has_env RELAYER_PRIVATE_KEY; then
  put_env RELAYER_PRIVATE_KEY 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
fi

# 학생 지갑 니모닉: 새로 만든다. Hardhat 기본 니모닉은 학생 주소가 임원 주소와 겹쳐 쓰지 않는다 (docs/SERVER_ENV.md 6절).
# 한번 만들면 바꾸지 않는다 — 바꾸면 학생 주소가 모두 바뀐다. 초기화해도 .env 의 값은 그대로 둔다
# 값이 있는데 니모닉이 아니면(주석이 값으로 읽힌 경우 등) 새로 만들지 않고 멈춘다. 학생 주소가 걸린 값이라 사람이 고친다
if has_env STUDENT_WALLET_MNEMONIC; then
  docker compose run --rm --no-deps -T api python -c \
    "import os; from eth_account import Account; Account.enable_unaudited_hdwallet_features(); Account.from_mnemonic(os.environ['STUDENT_WALLET_MNEMONIC'])" \
    >/dev/null 2>&1 || {
    echo ".env 의 STUDENT_WALLET_MNEMONIC 이 올바른 BIP-39 니모닉이 아닙니다. 직접 고치세요 (바꾸면 학생 주소가 모두 바뀝니다)." >&2
    exit 1
  }
else
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
