# 공용 개발 스택

통합 시험에 쓰는 서버다. `db`·`chain`·`api` 세 컨테이너를 VM 한 대에 띄운다. 발표는 Amoy 배포를 따로 쓰고, 개인 개발은 지금처럼 `CHAIN_FAKE=1` 로 한다.

## 접속

- Tailscale 네트워크에 들어온 뒤 `http://<서버 Tailscale IP>:8000` 으로 접속한다. API 문서는 `/docs`.
- 서버 주소는 팀 채팅에서 확인한다. 공개 저장소이므로 커밋하지 않는다.
- 밖으로 여는 포트는 API 하나다. RPC(8545)와 DB 는 열지 않는다. Hardhat 키는 공개되어 있어서 RPC 가 열리면 누구나 체인을 조작할 수 있다.

## 처음 띄우기와 초기화

VM 에서 저장소 루트에 있을 때 실행한다.

```bash
git pull
bash scripts/dev-stack-reset.sh
```

체인과 DB 를 지운 뒤 배포, 마이그레이션, 시드, 체인 예산 발행까지 진행한다. `.env` 가 없으면 비밀값과 Tailscale 주소를 넣어 새로 만든다.

기본 초기화는 행사비·사업비·운영비를 체인에 발행한다. 한 학기·한 항목에 예산은 하나라서 이 세 항목을 예산 편성 화면에서 다시 발행하면 `ALREADY_ISSUED` 로 끝난다. 편성 화면을 시험할 때는 체인 발행을 건너뛴다.

```bash
bash scripts/dev-stack-reset.sh --no-budgets
```

**VM 을 재시작했거나 `chain` 컨테이너가 다시 시작되면 이 스크립트를 실행해야 한다.** 체인은 메모리에만 저장되어 지워지지만 DB 는 남아 서로 어긋난다.

## 코드만 반영하기

데이터를 유지한 채 API 코드만 바꿀 때 실행한다. `--no-deps` 를 빼면 `chain` 까지 다시 만들어져 체인만 지워지고 DB 는 남을 수 있다. 새 코드가 먼저 뜨지 않도록 마이그레이션을 API 재시작보다 먼저 실행한다.

```bash
git pull
docker compose build api
docker compose run --rm --no-deps api alembic upgrade head
docker compose up -d --no-deps api
```

## 상태 확인

```bash
docker compose ps
docker compose logs api --tail 50
```

## 시험 계정

`backend/README.md` 의 계정을 쓴다. 공개된 Hardhat 키로 서명하는 개발 전용 계정이며, 실제 임원 지갑을 쓰는 발표용 Amoy 배포와는 별개다.
