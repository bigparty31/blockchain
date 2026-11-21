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

루트 `.env` 에 `POSTGRES_PASSWORD`, `JWT_SECRET`, `STUDENT_WALLET_MNEMONIC`,
`STUDENT_DB_PASSWORD` 가 있어야 한다 (`docs/SERVER_ENV.md`). 저장소 루트에서:

```bash
docker compose -f docker-compose.yml -f deploy/docker-compose.student.yml up -d

# 학생 서버는 읽기 전용 계정으로 붙는다 (PRD §9.1). 마이그레이션 뒤에 한 번 돌린다 —
# 테이블이 있어야 GRANT 가 걸린다. 여러 번 돌려도 안전하다.
docker compose exec -T api alembic upgrade head

# **.env 는 compose 만 읽는다. 셸로 따로 가져와야 한다** — 안 그러면 빈 문자열로 치환되어
# 비밀번호가 빈 계정이 만들어지고, 앱만 password authentication failed 로 실패한다.
export $(grep -E '^STUDENT_DB_PASSWORD=' .env | xargs)

docker compose exec -T db psql -U council -d council \
  -v student_ro_password="$STUDENT_DB_PASSWORD" -f /dev/stdin < deploy/student-ro.sql
```

계정을 만들기 전에는 학생 API 로그에 `password authentication failed for user "student_ro"` 가
뜨고 조회가 전부 실패한다. 그때는 위 스크립트를 먼저 돌린다.

- 학생 API: `http://127.0.0.1:8001` (nginx 를 거친다)
- 임원 API: `http://127.0.0.1:8000` (기존 그대로)

분배가 실제로 되는지 확인 — 응답 헤더 `X-Upstream` 이 두 주소를 번갈아야 한다:

```bash
for i in $(seq 10); do curl -s -o /dev/null -D - http://127.0.0.1:8001/ | grep -i x-upstream; done
```

## 재기

**① 장부를 실제 규모로 채운다.** 기본 시드는 확정 2건이라 `/entries` 가 체인을 2번만 부른다.
그 상태로 재면 **캐시가 아끼는 양이 실제의 1/80 로 나온다** — `/entries` 는 건수만큼 체인
`get_entry` 를 부르기 때문이다.

```bash
cd backend && python -m scripts.seed && cd ..          # 기본 시드(사용자·예산·학기)
docker compose exec -T db pg_dump -U council -d council -Fc > /tmp/before_seed.dump   # 되돌릴 수 있게
docker compose exec -T -e SEED_COUNT=150 api python - < deploy/seed_load_fixture.py   # 약 20초
```

되돌리기: `docker compose exec -T db pg_restore -U council -d council --clean --if-exists < /tmp/before_seed.dump`

**② 두 번 다 같은 데이터로 잰다.** k6 는 Docker 로 돌리는 쪽이 맞다 — `127.0.0.1:8001` 로 때리면
맥에서는 Docker Desktop 포트 포워딩이 p95 에 자기 지분을 만들어, 서버가 빨라진 것인지 포워딩이
흔들린 것인지 구분되지 않는다. 컨테이너 안에서 `student-lb` 로 직접 때리면 그 구간이 빠진다.

```bash
# ① 캐시 켜고
CACHE_ENABLED=1 docker compose -f docker-compose.yml -f deploy/docker-compose.student.yml up -d
docker compose restart student-lb        # ← 아래 「반드시 LB 도 재시작」 참고
docker compose exec -T redis redis-cli FLUSHALL
docker run --rm -i --network blockchain_default grafana/k6 \
  run -e BASE=http://student-lb:8001 - < deploy/k6/read_mix.js | tee deploy/k6/result-cache-on.txt

# ② 캐시 끄고 (같은 스크립트, 같은 데이터)
CACHE_ENABLED=0 docker compose -f docker-compose.yml -f deploy/docker-compose.student.yml up -d
docker compose restart student-lb
docker compose exec -T redis redis-cli FLUSHALL
docker run --rm -i --network blockchain_default grafana/k6 \
  run -e BASE=http://student-lb:8001 - < deploy/k6/read_mix.js | tee deploy/k6/result-cache-off.txt
```

> **반드시 LB 도 같이 재시작한다.** 컨테이너를 다시 만들면 IP 가 바뀌는데 **nginx 는 기동할 때
> 잡은 upstream IP 를 계속 쓴다.** 재시작하지 않으면 두 대 중 한 대가 죽은 IP 로 남아, 요청마다
> 그쪽에 먼저 시도하고 실패한 뒤 나머지 한 대로 넘긴다 — 즉 **한 대로만 부하를 받으면서
> 「2대 구성」 수치라고 보고하게 된다.** 측정 전에 LB 를 거치지 않고 두 대를 직접 확인한다:
>
> ```bash
> for c in student-api-1 student-api-2; do
>   ip=$(docker inspect blockchain-$c-1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
>   echo -n "$c($ip) = "
>   docker run --rm --network blockchain_default curlimages/curl -s -o /dev/null -w '%{http_code}\n' http://$ip:8001/
> done
> ```

보고할 값은 `http_req_duration` 의 **p(95)** 와 `http_req_failed` 비율, 그리고 엔드포인트별
`dur_entries` · `dur_balance` · `dur_budgets` · `dur_entry_detail` 이다.

> **`/budgets` 가 가장 크게 갈릴 것이다.** 예산마다 체인 `get_budget` 을 부르기 때문에 캐시를 끄면
> 요청 하나가 RPC 왕복 3번이 된다. 비교 표에 이 줄을 따로 두면 캐시가 왜 필요한지가 숫자로 보인다.

## 측정할 때 주의

- **`http_req_failed` 를 먼저 보고, 1% 아래일 때만 `p(95)` 를 말한다.** 실패한 요청은 빠르게
  끝나서 p95 를 **낮춘다**. 실패율 80% 인 측정이 `p(95)=8ms ✓` 로 통과 표시가 뜨는데, 그건
  성공한 20% 만의 분포라 아무 의미가 없다. 실제로 그렇게 나온 측정이 있었다.
- **`--build` 로 스택을 올리지 않는다.** `contracts/` 가 바뀐 상태에서 `up --build` 를 하면
  `chain` 이미지까지 재빌드되어 컨테이너가 교체되고, Hardhat 은 인메모리라 **컨트랙트와 온체인
  기록이 전부 날아간다.** DB 는 남으므로 `/balance`·`/entries` 는 200 인데 `/budgets` 만 503 인
  — **반만 고장 난** 상태가 된다. 학생 API 만 다시 빌드한다:
  ```bash
  docker compose -f docker-compose.yml -f deploy/docker-compose.student.yml build student-api-1 student-api-2
  docker compose -f docker-compose.yml -f deploy/docker-compose.student.yml up -d --no-deps student-api-1 student-api-2
  ```
  이미 비워졌으면 `contracts` 에서 재배포하고 `python -m scripts.issue_seed_budgets` 로 예산을
  다시 발행해야 한다. 기존 항목의 온체인 기록은 복구 수단이 없다.
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

## 캐시 동작과 한계

- `/balance` · `/entries` · `/budgets` 조회 라우터가 `backend/app/cache.py` 를 사용한다.
  `CACHE_ENABLED=1` 로 올리면 Redis TTL 캐시(기본 `CACHE_TTL_SECONDS=30`초)가 동작하며,
  `CACHE_ENABLED=0` 이거나 Redis 에 연결할 수 없으면 원본(DB·체인)을 직접 조회한다(fail-open).
- **한계**: `/balance` · `/entries` · `/budgets` 는 각자 독립된 캐시 키로 만료되므로,
  새 항목이 확정되거나 예산이 갱신된 직후 최대 TTL(기본 30초) 동안 세 조회가 서로 다른 숫자를 보일 수 있다.

## 측정에서 나온 것

**장부 확정 155건 · 인스턴스 2대 · 150 VU · 본 스크립트 2분 구간**(30초 ramp → 1분 peak → 30초 down).

| 구성 | 실패율 | p95 | 성공 응답 평균 |
|---|---|---|---|
| 캐시 없음 (`CACHE_ENABLED=0`) | **99.77%** | — | 491ms |
| 캐시만 | **37.94%** | — | 13.06ms |
| 캐시 + 단일 비행 + 풀 25+10 | **0.00%** | **13.46ms** | 10.96ms |

마지막 줄이 목표(**피크 동시 150 · p95 300ms**) 달성이다 — p95 가 목표의 **1/22** 이고 체크
29,950건 전부 성공했다. 엔드포인트별 p95 는 `/balance` 6.8ms · `/budgets` 8.76ms ·
`/entries` 10.03ms · `/entries/{id}` 36.18ms 다.

**세 조각이 각각 무엇을 막고 있었는지** 하나씩 떼어 재 본 결과다. 어느 하나라도 빠지면 목표를
못 맞춘다:

| 빠진 것 | 어디서 무너지나 |
|---|---|
| 캐시 (라우터 연결) | **4 VU** 에서 이미 p95 584ms — 목표 초과 |
| 단일 비행 | 24 VU 가 상한. 32 VU 에서 100% 실패 |
| 풀 설정 | 150 VU 2분에서 37.94% 실패 |

### 캐시를 끄면 왜 그렇게 무너지나

`/entries` 는 장부 건수만큼 체인 `get_entry` 를 부르고, `/budgets` 는 예산마다 `get_budget` 을
부른다. 155건이면 조회 한 번이 체인 왕복 155번이다. 캐시는 이걸 통째로 없앤다 — 적중하면 DB 도
체인도 가지 않는다.

### 단일 비행이 왜 필요한가

TTL 이 끝나는 순간 그때 들어온 요청 **전부**가 미스가 되어 한꺼번에 생성 경로로 들어간다.
생성 경로는 DB 커넥션을 쥔 채 체인 조회를 기다리므로(최대 1.5초), 동시 요청이 풀 크기를 넘으면
남은 요청이 커넥션을 **이벤트 루프 위에서** 기다리고 그 동안 그 인스턴스는 아무 요청도 처리하지
못한다. 만료 순간의 생성을 인스턴스당 1회로 묶어야 한다 — 측정은 그 보호를 넣고 쟀다.

**구현과 라우터 연결은 PR #134(김경윤)에서 반영됐다** — `app/cache.py` 가 키별로 진행 중인 Future 를
공유하는 방식이며, `/balance` · `/entries` · `/budgets` 조회 라우터가 `get_or_set` 을 호출한다.
캐시 동작과 한계(세 조회의 TTL 어긋남 등)는 위 「캐시 동작과 한계」에 정리했다.

루프가 막히는 것은 이렇게 확인했다 — `/entries` 에 부하를 주면서 DB 를 전혀 쓰지 않는 `/` 를 쟀다:

| 부하 | 풀(35) 대비 | `/` 응답 |
|---|---|---|
| `/balance` 60 동시 (체인 안 씀) | 초과 | 1~3ms |
| `/entries` 30 동시 | 이하 | 1~3ms |
| `/entries` 60 동시 | 초과 | **30초 타임아웃** |

### 풀 설정 (백엔드와 맞출 것)

`app/database.py` 가 `create_engine(DATABASE_URL, connect_args=connect_args)` 뿐이라 풀이
**기본값(`pool_size=5, max_overflow=10`)** 이다. 인스턴스당 동시 15건이 천장이고, 캐시가
안 걸린 `/entries/{id}` 상세가 요청마다 DB 를 타므로 150 VU 에서 이 천장에 걸린다.

측정에 쓴 값은 `pool_size=25, max_overflow=10` 이다. 공용 파일이라 **저장소에는 넣지 않았다** —
소유자와 맞춘 뒤 들어가야 한다. 요청할 내용:

```python
engine = create_engine(
    DATABASE_URL,
    connect_args=connect_args,
    pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
    max_overflow=int(os.getenv("DB_MAX_OVERFLOW", "10")),
    pool_pre_ping=True,
)
```

환경변수로 열어 두면 **학생 서버만 키우고 임원 서버는 기본값으로 둘 수 있다.** 다만 늘릴 때
Postgres `max_connections`(기본 100)를 넘지 않게 봐야 한다 — 학생 2대 × 35 + 임원 15 = 85 다.
`pool_pre_ping` 은 부하와 무관한 별개 건이지만 같은 호출이라 함께 넣는 쪽이 낫다 (DB 재시작 뒤
풀에 남은 죽은 커넥션 문제).

## 아직 안 한 것

- **풀 설정이 저장소에 없다.** 위 요청이 반영되기 전까지 `CACHE_ENABLED=1` 로 올려도 150 VU
  2분에서 37.94% 실패한다. 24 VU 까지는 그대로도 실패 0% 다.
- **제출 수치는 공용 서버에서 다시 재야 한다.** 로컬은 k6 와 서버가 같은 Docker VM(CPU 8개)을
  나눠 쓴다. 구성별 비교는 같은 조건이라 그대로 유효하지만 절대값은 환경에 묶인다.
