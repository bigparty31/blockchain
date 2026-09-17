# AUTH — 인증·권한

작성 손종인 · 대상 김경윤(API에서 권한 쓰기), 이승호·장정아(앱 로그인·지갑 등록) · 코드 `backend/app/auth/` · 테스트 `backend/tests/test_auth.py`

PRD는 "로그인 후 role 분기"와 역할 4개만 정해 두었다. 아래 §1은 그 위에 정한 기본안이고, 바꿀 수 있다. 서버에는 아직 붙이지 않았다 (§5).

---

## 1. 정한 것

| 항목 | 정한 내용 | 이유 |
| --- | --- | --- |
| 로그인 | **학번 + 비밀번호** | PRD `User`에 이메일·외부 계정이 없다 |
| 비밀번호 저장 | scrypt (표준 라이브러리) | 의존성을 늘리지 않는다 |
| 첫 로그인 | **비밀번호를 바꾸기 전에는 다른 API를 못 쓴다** (`PASSWORD_CHANGE_REQUIRED`) | 계정은 관리자가 만든 비밀번호로 시작한다 |
| 토큰 | JWT(HS256) 액세스 토큰, 기본 12시간 | 모바일 앱에서 쓰기 쉽다 |
| 토큰 무효화 | 요청마다 사용자를 다시 읽어 `token_version`·활성 여부를 본다 | 비밀번호·역할을 바꾸거나 계정을 막으면 **이미 나간 토큰도 바로 무효** |
| 역할 판단 | 토큰의 role이 아니라 **다시 읽은 사용자 값**으로 한다 | 역할을 바꾼 뒤 옛 토큰으로 옛 권한을 쓰지 못한다 |
| 로그인 실패 | 없는 학번·틀린 비밀번호·막힌 계정을 구분하지 않는다. 없는 학번도 같은 시간을 쓴다 | 가입 여부를 알아낼 수 없게 |
| 임원 지갑 | 기기 키스토어 주소를 **서명으로 확인하고** 등록한다 (§4) | 남의 주소나 키가 없는 주소가 등록되면 검증이 깨진다 |
| 학생 지갑 | 서버 HD 지갑에서 **주소만** 파생한다 (`m/44'/60'/0'/0/{wallet_index}`) | PRD §9.2. 학생은 체인에 쓰지 않는다 |
| 주소 → 사람 | 임원 주소만 알려준다. 키를 바꾸기 전 주소도 찾는다. **학생 주소는 알려주지 않는다** | 단건 검증(HASHING §2)은 등록자·승인자만 필요하고, 학번↔주소 매핑은 공개하지 않는다 (PRD §7.1) |

## 2. API

모두 `/auth` 아래. 로그인 말고는 `Authorization: Bearer <토큰>`이 필요하다.

| 요청 | 본문 | 응답 | 비고 |
| --- | --- | --- | --- |
| `POST /auth/login` | `student_no`, `password` | `access_token`, `expires_in`, `user` | 틀리면 401 `INVALID_CREDENTIALS` |
| `GET /auth/me` | — | `user` | 비밀번호를 바꿔야 하는 계정도 된다 |
| `POST /auth/password` | `old_password`, `new_password` | 새 `access_token` | 8자 이상. 다른 기기의 토큰은 모두 무효 |
| `POST /auth/wallet/challenge` | — | `nonce`, `message`, `expires_at` | 임원만. 5분 유효, 한 번만 쓴다 |
| `POST /auth/wallet` | `nonce`, `address`, `signature` | `user` | 임원만 (§4) |
| `GET /auth/addresses/{address}` | — | `AddressOwner` 또는 `null` | 로그인한 누구나. 임원 주소만 찾는다 |

`user` = `id`, `student_no`, `name`, `role`, `wallet_address`(임원은 등록한 주소·없으면 null, 학생은 파생 주소), `password_change_required`

에러 본문은 `{"detail": {"code": "...", "detail": "..."}}`. 401은 토큰·로그인 문제, 403은 역할 없음(`FORBIDDEN`)·비밀번호 변경 필요(`PASSWORD_CHANGE_REQUIRED`), 409는 학번·지갑 중복.

## 3. 다른 API에서 권한 쓰기

```python
from fastapi import Depends
from app.auth import User, UserRole, current_user, require_roles

@router.post("/entries/drafts")
async def open_draft(user: User = Depends(require_roles(UserRole.TREASURER))):
    ...  # user.id → created_by, user.wallet_address → registrant

@router.get("/entries")
async def list_entries(user: User = Depends(current_user)):  # 로그인한 누구나
    ...
```

PRD §3의 역할표를 옮기면:

| 역할 | 할 수 있는 것 |
| --- | --- |
| `STUDENT` | 열람, 검증, 이의 제기, 본인 SBT·QR |
| `TREASURER` | 수입·지출 등록, 승인 전 수정, 정정 요청 |
| `AUDITOR` | 승인·반려, 이의 답변, 예산 개정 승인 |
| `PRESIDENT` | 예산 편성, 감사와 같은 승인 권한, 키 교체 공동 서명 |

`APPROVER_USER_ROLES`(감사·회장), `OFFICER_ROLES`(임원 셋)를 쓰면 된다. **서버의 역할 검사는 1차 방어다.** 확정·반려 같은 체인 쓰기는 컨트랙트가 서명자 롤을 다시 본다.

## 4. 임원 지갑 등록

```
① POST /auth/wallet/challenge            → message (학생회비 장부 지갑 등록 / user / nonce / expires)
② 앱: 기기 키스토어 키로 message 를 personal_sign (EIP-191)
③ POST /auth/wallet {nonce, address, signature}
   서버: nonce 가 살아 있고 한 번도 안 썼는지 → 서명에서 복구한 주소 == address 인지 → 등록
```

- **`address`를 함께 받는 이유** — 서명만 받으면, 앱이 문장을 조금 다르게 서명했을 때 아무도 키를 갖지 않은 엉뚱한 주소가 등록된다
- **키 교체** — 새 주소를 같은 방법으로 등록하면 이전 주소는 은퇴(`retired_at`)로 남는다. 지난 서명은 옛 주소로 남아 있어서 지우지 않는다. 한 번 쓴 주소는 다른 사람도, 본인도 다시 등록할 수 없다 (`WALLET_TAKEN`)
- **역할 변경** — 임원에서 학생이 되면 지갑을 은퇴시킨다. 다시 임원이 되면 새로 등록해야 한다 (그사이 기기를 잃었을 수 있다). 임원끼리 바뀌면(감사 → 회장) 지갑을 그대로 둔다
- **체인 롤은 따로다** — 서버에 주소를 등록해도 RoleManager 롤은 바뀌지 않는다. 롤 부여·키 교체는 회장·감사가 직접 보내야 한다 (CHAIN_CLIENT §8)

## 5. 서버에 붙이기 (아직 안 함)

```python
from app.auth import AuthService, AuthSettings, get_auth_service
from app.auth.router import router as auth_router
from app.chain.wallets import StudentWallets, mnemonic_from_env

wallets = StudentWallets(mnemonic_from_env())  # 잘못된 니모닉이면 여기서 ValueError. 니모닉은 이후 들고 있지 않는다
auth = AuthService(user_store, AuthSettings.from_env(), student_wallets=wallets)
app.include_router(auth_router)
app.dependency_overrides[get_auth_service] = lambda: auth
```

| 환경변수 | 뜻 | 기본값 |
| --- | --- | --- |
| `AUTH_SECRET` | 토큰 서명 키. 32바이트 이상 무작위 값. 저장소에 넣지 않는다 | — (필수) |
| `AUTH_TOKEN_TTL_SECONDS` | 토큰 유효 시간 | 43200 (12시간) |
| `AUTH_CHALLENGE_TTL_SECONDS` | 지갑 등록 문장 유효 시간 | 300 |
| `STUDENT_WALLET_MNEMONIC` | 학생 지갑 파생 니모닉. 저장소에 넣지 않는다 | — (학생 주소가 필요할 때) |

**DB 저장소(`UserStore`)가 지킬 것** — 코드에는 테스트용 `InMemoryUserStore`만 있다.

- **사용자를 통째로 덮어쓰지 않는다** — `update`는 바꿀 칼럼만, `token_version`이 읽었을 때 그대로일 때만 바꾼다 (`UPDATE users SET ... WHERE id = :id AND token_version = :v`). 요청 처음에 읽은 사용자로 덮으면 그사이 관리자가 한 비활성화·역할 변경이 되살아나기 때문이다. 버전이 달라져 있으면 요청은 `INVALID_TOKEN`으로 끝난다
- `users.student_no` 유니크, `wallet_index`는 시퀀스 — 한 번 준 번호는 다시 주지 않는다
- `wallet_records.address` 유니크(대소문자 구분 없이) — 은퇴한 주소도 포함. 버전 확인·이전 주소 은퇴·새 주소 등록·`users.wallet_address` 갱신은 한 트랜잭션
- 지갑 등록 문장은 꺼내면서 지운다 — 같은 문장으로 두 번 등록하지 못하게

## 6. 정하지 않은 것

| 무엇 | 누구와 | 왜 |
| --- | --- | --- |
| 계정을 누가 어떻게 만드나 | 팀 (문승준 — 납부 명단) | 학생은 명단 일괄 등록, 임원은 회장이 지정하는 식이 자연스럽지만 경로(CSV·관리 화면)와 초기 비밀번호 전달 방법이 없다. 지금은 `create_user`·`change_role`·`deactivate` 서비스만 있다 |
| 비밀번호 분실 | 팀 | 이메일·전화번호가 `User`에 없어 스스로 재설정할 수단이 없다. 관리자가 초기화하는 쪽이 현실적이다 |
| 로그인 시도 제한 | 손종인 | 학번은 추측하기 쉬워서 필요하다. 서버 연결 때 IP·학번별 제한을 붙인다 |
| 체인 롤과 DB 역할이 어긋날 때 | 손종인 | DB에서 역할을 바꿔도 체인 롤은 회장이 따로 바꾼다. `/auth/me`에 체인 롤(`RoleReader.has_role`)을 함께 보여줄지 |
