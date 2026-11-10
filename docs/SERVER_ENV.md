# 서버 환경변수 — 학생회 서버·학생 서버

PRD §9.1의 두 서버(`council_api`, `student_api`)에 넣을 환경변수 목록이다. docker-compose 서비스 넷을 정의할 때 쓴다.
값은 적지 않는다. 어디서 만들고 누가 갖고 있는지만 적는다.

- 코드는 하나이고 실행 단위만 둘이다. **두 서버는 같은 변수 이름을 읽고 값만 다르게 받는다.**
- 이미 설정된 환경변수가 저장소 루트 `.env`보다 우선한다 (`backend/app/env.py`). 컨테이너에는 compose가 넣은 값이 쓰인다.
- 비밀값은 커밋하지 않는다. `.env`, `.env.*`는 `.gitignore`에 있다 (`.env.example`만 예외).
- 아직 머지되지 않은 PR이 읽는 변수는 PR 번호를 붙였다. 머지 전에는 넣어도 아무 효과가 없다.

## 1. 규정

| 규정 | 내용 | 근거 |
|---|---|---|
| 학생 서버 | 조회만 한다. DB는 **읽기 전용 계정**, **릴레이어 키·FCM 키 없음**, 학생 롤 토큰만 받는다. 여러 대 띄울 수 있다 | PRD §9.1 |
| 학생회 서버 | 쓰기·릴레이·푸시를 한다. DB는 읽기·쓰기 계정. **1대, uvicorn 워커 1개** (릴레이어 nonce 순서, 재알림 작업) | PRD §9.1, §4.8 |
| 로그인 | `/auth/login`은 양쪽에 있고, 각 서버는 자기 롤이 아닌 토큰을 받지 않는다 | PRD §9.1 |
| 키 | 서버는 임원 키를 갖지 않는다. 릴레이어 지갑은 어떤 롤도 갖지 않는다. 학생회 서버가 첫 체인 요청 때 점검하고, 롤이 있으면 체인을 쓰지 않는다 | PRD §9.2 |
| FCM | 서비스 계정 비공개 키는 커밋하지 않는다. `google-services.json`은 앱에 커밋한다 | PRD §4.8 |

## 2. 서버별 변수

O는 넣는다, **비움**은 넣지 않거나 빈 값으로 둔다는 뜻이다.

| 변수 | 학생회 서버 | 학생 서버 | 비밀 | 없거나 틀리면 |
|---|---|---|---|---|
| `DATABASE_URL` | O 읽기·쓰기 계정 | O **읽기 전용 계정** | O | 없으면 컨테이너 안 SQLite 파일로 뜬다. 반드시 넣는다 |
| `JWT_SECRET` | O | O **학생회 서버와 다른 값** (6절) | O | 서버가 뜨지 않는다 |
| `CHAIN_RPC_URL` | O | O | Amoy는 O (주소에 API 키가 들어간다) | `CHAIN_FAKE`도 없으면 서버가 뜨지 않는다 |
| `DEPLOYMENTS_FILE` | O | O 같은 파일 | | 없으면 `contracts/deployments/localhost.json`을 읽는다. 컨테이너에는 그 경로가 없다 |
| `RELAYER_PRIVATE_KEY` | O | **비움** | O | 비우면 체인을 조회만 한다. 쓰기 API는 503이다 |
| `STUDENT_WALLET_MNEMONIC` | O | O 같은 값 (6절) | O | 회원권 조회(`/memberships/me`)가 503이다. SBT 발행 대상 주소를 만들 수 없다 |
| `OCR_API_KEY` | O | **비움** | O | OCR이 판정 불가(`UNREADABLE`)로 떨어진다 |
| `OCR_INVOKE_URL` | O | **비움** | | 위와 같다 |
| `GOOGLE_APPLICATION_CREDENTIALS` | O 키 파일 경로 | **비움** | 파일이 O | 푸시를 보내지 못한다. FCM 전송 모듈(장정아)이 붙은 뒤부터 읽는다 |
| `NOTIFICATION_WORKER` (#79) | `1` | `0` | | 기본 `1`. 재알림 작업은 DB에 쓴다. 학생 서버 진입점(#77)은 작업을 켜지 않지만, 진입점을 잘못 지정해도 켜지지 않게 `0`을 둔다 |
| `NOTIFICATION_REMIND_SECONDS` (#79) | 비움 (기본 86400) | 비움 | | 0 이하이거나 숫자가 아니면 서버가 뜨지 않는다. 시연에서만 줄인다 |
| `NOTIFICATION_TICK_SECONDS` (#79) | 비움 (기본 60) | 비움 | | 위와 같다 |
| `NOTIFICATION_DEADLINE_NEAR_SECONDS` (#79) | 비움 (기본 21600) | 비움 | | 위와 같다 |
| `RECEIPTS_STORAGE_DIR` (#66) | O 공유 볼륨, 쓰기 | O 같은 볼륨, **읽기 전용** | | 없으면 컨테이너 안 `uploads/receipts`에 저장되어 재생성하면 사라진다 |

**두 서버 모두 넣지 않는 것**

| 변수 | 이유 |
|---|---|
| `JWT_DEV_SECRET` | 저장소에 공개된 개발용 키로 토큰을 서명한다. 누구나 임원 토큰을 만들 수 있다 |
| `CHAIN_FAKE` | 체인에 아무것도 기록하지 않고 가짜 서명도 통과시킨다 |

`OPENBANKING_*`는 읽는 코드가 없어 `.env.example`에서 지웠다. 오픈뱅킹은 이용 자격 요건 때문에 발급받을 수 없어 범위에서 빠졌다 (PRD §4.6).

## 3. 값의 출처

| 변수 | 공용 개발 스택 | 발표용 Amoy |
|---|---|---|
| `DATABASE_URL` | compose의 `db` 서비스. 학생회 서버는 `council` 계정, 학생 서버는 읽기 전용 계정 (5절) | 같다. 비밀번호는 새로 만든다 |
| `JWT_SECRET` | `.env`에서 서버마다 하나씩 (6절) | 새로 만든다 |
| `CHAIN_RPC_URL` | `http://chain:8545` | Amoy RPC 제공자 주소 (chainId 80002) |
| `DEPLOYMENTS_FILE` | `/deployments/localhost.json` (배포 볼륨, 읽기 전용) | Amoy 배포 결과 파일 (장석연) |
| `RELAYER_PRIVATE_KEY` | 비우면 진입 스크립트가 Hardhat 공개 키를 넣는다 (`docker-entrypoint.sh`) | **반드시 넣는다.** 새 지갑을 만들어 POL을 충전하고 롤은 주지 않는다 |
| `STUDENT_WALLET_MNEMONIC` | 새로 만든다 (6절) | 새로 만든다. 이후 바꾸지 않는다 |
| `OCR_API_KEY`, `OCR_INVOKE_URL` | CLOVA OCR 콘솔 (`docs/OCR.md`) | 같다 |
| `GOOGLE_APPLICATION_CREDENTIALS` | Firebase 콘솔 → 프로젝트 설정 → 서비스 계정 → 새 비공개 키 | 같다 |
| `RECEIPTS_STORAGE_DIR` | 공유 볼륨의 마운트 경로 (예: `/receipts`) | 같다 |

공용 개발 스택에서 `RELAYER_PRIVATE_KEY`를 비우는 것은 Hardhat 노드라서 괜찮다. Amoy에서 비우면 공개된 Hardhat 키가 들어가므로 반드시 값을 넣는다.

## 4. 실행 조건

변수가 아니라 compose 정의에 들어가는 조건이다.

| | 학생회 서버 (`council_api`) | 학생 서버 (`student_api`) |
|---|---|---|
| 진입점 (#77) | `app.main_council:app` | `app.main_student:app` |
| uvicorn 워커 | **1개** (`--workers`를 주지 않는다) | 여러 개 가능 |
| 대수 | **1대.** 확장 구성에서도 늘리지 않는다 | 기본 1대, 확장 구성 2대 + nginx |
| 진입 스크립트 | 거친다 (개발 스택 릴레이어 키) | **거치지 않는다** |
| 배포 파일 볼륨 | 읽기 전용 | 읽기 전용 |
| 영수증 볼륨 | 읽기·쓰기 | 읽기 전용 |

**학생 서버는 진입 스크립트를 거치지 않는다.** 이미지의 `ENTRYPOINT`인 `docker-entrypoint.sh`는 `RELAYER_PRIVATE_KEY`가 비어 있으면 Hardhat 릴레이어 키를 채운다. 학생 서버가 이 스크립트를 거치면 릴레이어 키를 갖게 되어 §9.1을 어긴다. compose에서 진입점을 비운다.

```yaml
  student_api:
    build: ./backend
    entrypoint: []
    command: ["uvicorn", "app.main_student:app", "--host", "0.0.0.0", "--port", "8000"]
```

**학생 서버의 영수증 조회.** 학생 앱은 영수증 원본을 내려받아 해시를 다시 계산한다(검증 3단계). 그래서 학생 서버에도 `GET /receipts/{filename}`이 있어야 하고, 같은 저장소를 읽기 전용으로 마운트한다. 업로드(`POST /receipts`)는 학생회 서버에만 둔다.

## 5. 학생 서버의 읽기 전용 DB 계정

계정 연결은 장정아 님 작업이다 (PRD §9.1). 아래는 PostgreSQL에서 만드는 예시다. 테이블은 마이그레이션이 나중에 만들기 때문에, 그 뒤에 생기는 테이블에도 조회 권한이 가도록 `ALTER DEFAULT PRIVILEGES`를 같이 둔다.

```sql
CREATE ROLE student_ro LOGIN PASSWORD '...';
GRANT CONNECT ON DATABASE council TO student_ro;
GRANT USAGE ON SCHEMA public TO student_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO student_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE council IN SCHEMA public GRANT SELECT ON TABLES TO student_ro;
```

로그인 실패 횟수를 DB에 두면(PRD §9.1 확장 구성) 학생 서버의 로그인이 그 테이블에 써야 한다. 그때 그 테이블 하나에만 쓰기 권한을 준다.

## 6. 비밀값 만들기와 보관

**`JWT_SECRET` — 학생회 서버와 학생 서버에 다른 값을 둔다.**

```sh
openssl rand -hex 32
```

- 값은 서버 **종류마다** 하나다. 확장 구성에서 학생 서버가 2대면 두 대는 같은 값을 쓴다. 다르면 nginx가 요청을 다른 대로 보낼 때마다 401이 난다

- 학생 서버가 발급한 토큰은 학생회 서버에서 서명 검증에 실패한다. 각 서버가 자기 롤이 아닌 토큰을 받지 않는다는 §9.1 규칙을 키로도 지킨다
- 학생 서버의 비밀이 새어도 학생회 서버에서 쓸 임원 토큰을 만들 수 없다
- 앱은 임원 계정이면 처음부터 학생회 서버로 로그인해야 한다. 학생 서버에서 받은 토큰을 학생회 서버에 보내면 401이다
- 값을 바꾸면 그 서버의 로그인이 모두 풀린다

**`STUDENT_WALLET_MNEMONIC` — 두 서버에 같은 값을 둔다.**

```sh
cd backend && python -c "from eth_account import Account; Account.enable_unaudited_hdwallet_features(); print(Account.create_with_mnemonic()[1])"
```

- 학생 주소는 `m/44'/60'/0'/0/{wallet_index}`로 파생한다 (`backend/app/services/student_wallet.py`). 학생회 서버는 SBT 발행 대상 주소를, 학생 서버는 회원권 조회 주소를 같은 니모닉에서 만든다
- **한번 정하면 바꾸지 않는다.** 바꾸면 모든 학생 주소가 바뀌어 이미 발행한 SBT와 맞지 않는다. 종이나 오프라인 저장소에 따로 보관한다
- Hardhat 기본 니모닉(`test test ... junk`)은 쓰지 않는다. 같은 경로라 학생 주소가 Hardhat 임원·릴레이어 주소와 겹친다
- 니모닉이 새면 학생 전원의 개인키가 노출된다. 다만 학생 키는 어떤 롤도 없고, 서버가 학생 키로 서명하는 쓰기도 없다 (§9.2). 그래서 장부·예산·SBT는 바꿀 수 없다

**`RELAYER_PRIVATE_KEY`**

- 새 지갑을 만든다. 임원 키나 배포자 키를 재사용하지 않는다
- Amoy에서는 가스비용 POL만 충전한다. 롤은 주지 않는다. 학생회 서버는 첫 체인 요청 때 이 주소를 점검한다. 롤이 있거나 잔액이 0이면 체인을 쓰는 요청이 모두 실패하고 이유가 로그에 남는다 (§9.2, `backend/app/chain/web3_client.py`)

**`GOOGLE_APPLICATION_CREDENTIALS`**

- 값은 키 파일의 **경로**다. JSON 내용을 환경변수에 넣지 않는다. 환경변수는 `docker inspect`와 오류 로그에 드러난다
- 키 파일은 compose secret이나 읽기 전용 볼륨으로 학생회 서버에만 마운트한다
- firebase-admin은 이 변수를 자동으로 읽는다. FCM 전송 모듈(장정아)이 같은 방식을 쓰는지는 모듈이 붙을 때 확인한다
