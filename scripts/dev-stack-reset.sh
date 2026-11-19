#!/usr/bin/env bash
# 공용 개발 스택을 처음 상태로 되돌린다: 체인·DB 삭제 → 배포 → 마이그레이션 → 시드 → 체인 예산 발행.
# VM 을 재시작해 체인이 지워졌을 때도 이것으로 복구한다. DB 내용도 함께 지워진다.
#   --yes         확인 없이 진행
#   --no-budgets  체인 예산 발행을 건너뛴다. 예산 편성 화면을 시험할 때 쓴다
# 임원을 실제 기기 주소로 배포하려면 OFFICER_PRESIDENT·OFFICER_TREASURER·OFFICER_AUDITOR1·OFFICER_AUDITOR2 를
# 넷 다 환경변수로 준다 (contracts/scripts/deploy.ts). 이때는 Hardhat 키로 예산을 발행할 수 없어 --no-budgets 가 필요하다.
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

officer_vars=(OFFICER_PRESIDENT OFFICER_TREASURER OFFICER_AUDITOR1 OFFICER_AUDITOR2)
device_officers=0
for v in "${officer_vars[@]}"; do
  [ -n "${!v:-}" ] && device_officers=1
done
if [ "$device_officers" -eq 1 ] && [ "$issue_budgets" -eq 1 ]; then
  echo "임원 주소 환경변수가 있으면 Hardhat 키로 예산을 발행할 수 없습니다. --no-budgets 를 붙이세요." >&2
  exit 2
fi

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
officer_env=()
for v in "${officer_vars[@]}"; do
  officer_env+=(-e "$v=${!v:-}")
done
docker compose exec -T "${officer_env[@]}" chain npx hardhat run scripts/deploy.ts --network localhost
docker compose build api
init_command="alembic upgrade head && python -m scripts.seed"
if [ "$issue_budgets" -eq 1 ]; then
  init_command="$init_command && python -m scripts.issue_seed_budgets"
fi
docker compose run --rm api sh -c "$init_command"
docker compose up -d api
echo "완료. 상태 확인: docker compose ps"
