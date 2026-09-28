# contracts

Solidity 컨트랙트. 규칙의 정본은 `interfaces/*.sol`, 요약은 `../docs/CONTRACTS.md`.

| 경로 | 내용 |
| --- | --- |
| `interfaces/` | 인터페이스 5종 (정본). `docs/` 가 이 경로를 참조한다 |
| `src/` | 구현. 이번 범위는 `RoleManager` `BudgetToken` `AccountingLedger` |
| `test/` | Mocha + ethers 테스트. `docs/CONTRACTS.md` "필수 테스트" 절 전 항목 |
| `scripts/deploy.ts` | 로컬 배포. 결과를 `deployments/<network>.json` 과 `deployments/abi/` 에 쓴다 |
| `deployments/` | 백엔드가 읽는 파일. 주소·chainId·DOMAIN_SEPARATOR·ABI |

## 도구

Hardhat 3 (ESM, TypeScript), solc 0.8.28, OpenZeppelin 5. Node 22 이상.

```bash
npm install
npx hardhat compile
npx hardhat test
```

테스트 끝에 함수별 가스 사용량 표가 찍힌다 (receipt.gasUsed 집계).

## 로컬 배포

```bash
# 터미널 1
npx hardhat node

# 터미널 2
npx hardhat run scripts/deploy.ts --network localhost
```

배포 순서는 `RoleManager(회장, 총무, 감사)` → `BudgetToken` → `AccountingLedger` → `BudgetToken.setLedger`. 세 임원은 생성자 인자라 롤 부여 단계가 없고, 끝나면 배포자에게 남는 권한이 없다.

계정은 Hardhat 기본 니모닉 순서를 그대로 쓴다. 개인키는 Hardhat 이 공개한 테스트 키라 저장소에 두지 않는다.

| 순번 | 역할 | 주소 |
| --- | --- | --- |
| 0 | 배포자 | `0xf39F…2266` |
| 1 | 회장 | `0x7099…79C8` |
| 2 | 총무 | `0x3C44…93BC` |
| 3 | 감사 | `0x90F7…b906` |
| 4 | 릴레이어 (롤 없음) | `0x15d3…6A65` |

노드를 새로 띄우면 nonce 가 0 부터라 컨트랙트 주소가 `deployments/localhost.json` 과 같게 나온다. 노드를 띄운 채로 다시 배포하면 주소가 달라지니 파일을 갱신하거나 노드를 재시작한다.

Amoy 등 외부 네트워크 배포는 아직 없다.
