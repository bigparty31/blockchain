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

docker compose down -v --remove-orphans
docker compose up -d --build --wait db chain
docker compose exec -T chain npx hardhat run scripts/deploy.ts --network localhost
docker compose build api
init_command="alembic upgrade head && python -m scripts.seed"
if [ "$issue_budgets" -eq 1 ]; then
  init_command="$init_command && python -m scripts.issue_seed_budgets"
fi
docker compose run --rm api sh -c "$init_command"
docker compose up -d api
echo "완료. 상태 확인: docker compose ps"
