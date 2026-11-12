# 학생 서버 수평 확장 구성과 부하 시험

담당 장정아 · 근거 PRD v0.15 §9.1, `문서/서버-분리-설계안.md` §3·§4

목표 수치는 **등록 학생 1,000명 · 피크 동시 150 · p95 300ms** 이고, 산출물은
**인스턴스 2개 + nginx 구성**과 **캐시 켜고/끈 k6 결과 비교**다.

## 무엇이 들어 있나

| 파일 | 내용 |
|---|---|
| `nginx.conf` | 학생 API 2개 앞단 로드밸런서 (`least_conn`, keepalive) |
| `docker-compose.student.yml` | 학생 API ×2 + Redis + nginx. 루트 compose 의 `db`·`chain` 을 그대로 쓴다 |
| `k6/read_mix.js` | 대시보드 조회 묶음 + 상세 조회. 150 VU 까지 올렸다 내린다 |

학생 API 자체는 이미 `backend/app/main_student.py` 에 있다 (`STUDENT_QUERY_ROUTERS` 만 마운트).
캐시는 `backend/app/cache.py` 이고 `CACHE_ENABLED` 로 켜고 끈다.

## 띄우기

루트 `.env` 에 `POSTGRES_PASSWORD`, `JWT_SECRET`, `STUDENT_WALLET_MNEMONIC` 이 있어야 한다
(`docs/SERVER_ENV.md`). 저장소 루트에서:

```bash
docker compose -f docker-compose.yml -f deploy/docker-compose.student.yml up -d
```

- 학생 API: `http://127.0.0.1:8001` (nginx 를 거친다)
- 임원 API: `http://127.0.0.1:8000` (기존 그대로)

분배가 실제로 되는지 확인 — 응답 헤더 `X-Upstream` 이 두 주소를 번갈아야 한다:

```bash
for i in $(seq 10); do curl -s -o /dev/null -D - http://127.0.0.1:8001/ | grep -i x-upstream; done
```

## 재기

시드가 들어 있어야 한다 (`cd backend && python -m scripts.seed`). 내역이 비면 k6 가 바로 멈춘다.

```bash
# ① 캐시 켜고
CACHE_ENABLED=1 docker compose -f docker-compose.yml -f deploy/docker-compose.student.yml up -d
k6 run -e BASE=http://127.0.0.1:8001 deploy/k6/read_mix.js | tee deploy/k6/result-cache-on.txt

# ② 캐시 끄고 (같은 스크립트, 같은 데이터)
CACHE_ENABLED=0 docker compose -f docker-compose.yml -f deploy/docker-compose.student.yml up -d
k6 run -e BASE=http://127.0.0.1:8001 deploy/k6/read_mix.js | tee deploy/k6/result-cache-off.txt
```

보고할 값은 `http_req_duration` 의 **p(95)** 와 `http_req_failed` 비율, 그리고 엔드포인트별
`dur_entries` · `dur_balance` · `dur_budgets` · `dur_entry_detail` 이다.

> **`/budgets` 가 가장 크게 갈릴 것이다.** 예산마다 체인 `get_budget` 을 부르기 때문에 캐시를 끄면
> 요청 하나가 RPC 왕복 3번이 된다. 비교 표에 이 줄을 따로 두면 캐시가 왜 필요한지가 숫자로 보인다.

## 측정할 때 주의

- **두 번 다 같은 데이터로 재야 한다.** 중간에 항목을 등록하면 목록 길이가 달라져 비교가 깨진다.
- 첫 30초(ramp)는 워밍업이다. 캐시 켠 쪽은 이 구간에 캐시가 비어 있어 느리다 — p95 를 전체
  구간으로 보면 캐시 효과가 과소평가된다. 필요하면 피크 1분 구간만 따로 뽑는다.
- k6 를 API 와 같은 기계에서 돌리면 150 VU 에서 k6 자신이 CPU 를 먹는다. 수치가 이상하면
  `--vus` 를 낮춰 가며 꺾이는 지점을 찾는다.

## docker 없이 재야 할 때

맥에 Docker Desktop 이 없으면 인스턴스 2개를 직접 띄우고 homebrew nginx 를 앞에 둘 수 있다.

```bash
cd backend
CACHE_ENABLED=0 .venv/bin/uvicorn app.main_student:app --port 8101 &
CACHE_ENABLED=0 .venv/bin/uvicorn app.main_student:app --port 8102 &
# nginx.conf 의 upstream 주소를 127.0.0.1:8101 / 8102 로 바꿔서 nginx -c 로 띄운다
```

**다만 제출용 수치는 compose 구성으로 재는 쪽이 맞다** — 구성 파일과 측정 환경이 다르면
「이 구성으로 잰 수치가 아니다」가 된다. 임시 확인용으로만 쓴다.

## 아직 안 한 것

- `cache.py` 를 조회 라우터에 **아직 연결하지 않았다.** `/balance` · `/entries` · `/budgets` 가
  대상이고, 이 라우터들은 공용 파일이라 소유자(김경윤)와 맞춘 뒤 붙인다. 붙이기 전까지
  `CACHE_ENABLED=1` 로 올려도 캐시는 동작하지 않는다.
- `redis` 패키지가 `backend/requirements.txt` 에 없다. 캐시를 실제로 켜기 전에 추가해야 한다
  (없으면 `cache.py` 가 경고만 남기고 캐시 없이 돈다).
- 읽기 전용 DB 계정 (`docs/SERVER_ENV.md` §5). 지금은 compose 가 `council` 계정을 그대로 쓴다.
