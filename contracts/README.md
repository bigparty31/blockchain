# contracts

Solidity 컨트랙트. 규칙의 정본은 `interfaces/*.sol`, 요약은 `../docs/CONTRACTS.md`.

| 경로 | 내용 |
| --- | --- |
| `interfaces/` | 인터페이스 5종 (정본). `docs/` 가 이 경로를 참조한다 |
| `src/` | 구현. 이번 범위는 `RoleManager` `BudgetToken` `AccountingLedger` |
| `mocks/` | 테스트 전용 컨트랙트 (`MockLedger`). 배포하지 않는다 |
| `test/` | Mocha + ethers 테스트. `docs/CONTRACTS.md` "필수 테스트" 절 전 항목 |
| `scripts/deploy.ts` | 로컬 배포. 결과를 `deployments/<network>.json` 과 `deployments/abi/` 에 쓴다 |
| `deployments/` | 백엔드가 읽는 파일. 주소·chainId·EIP-712 도메인 3개·ABI. JSON 안의 abi 경로는 `deployments/` 기준 |

## 도구

| 도구 | 버전 |
| --- | --- |
| Node.js | 22 이상 (22.23 에서 확인) |
| Hardhat | 3.18.0 |
| @nomicfoundation/hardhat-toolbox-mocha-ethers | 4.0.0 |
| ethers | 6.17.0 |
| mocha / chai | 12.0.2 / 6.2.2 |
| @openzeppelin/contracts | 5.6.1 |
| solc | 0.8.28 (evm target cancun) |
| TypeScript | 5.9.3 (타입 검사용. 실행은 Node 의 타입 스트리핑) |

`package.json` 의 버전은 `^` 없이 고정했다. 다른 OpenZeppelin·solc 로 컴파일되면 커밋된 ABI·DOMAIN_SEPARATOR 와 달라질 수 있기 때문이다. `package-lock.json` 은 저장소 루트 `.gitignore` 규칙으로 커밋하지 않으므로 `npm ci` 가 아니라 `npm install` 을 쓴다.

> **Hardhat 2 튜토리얼과 다르다.** 웹에 있는 대부분의 예제는 Hardhat 2 기준이다. 이 프로젝트는 Hardhat 3 라서 다음이 다르다.
> - 설정이 ESM `defineConfig(...)` 다. `require("@nomicfoundation/hardhat-toolbox")` 형태가 아니다.
> - 테스트·스크립트에서 `hre.ethers` 를 바로 쓰지 않는다. `const { ethers } = await network.getOrCreate()` 로 연결을 얻는다.
> - chai 매처 이름이 바뀌었다. `.to.be.reverted` 가 아니라 `.to.be.revert(ethers)`, `.revertedWithCustomError(contract, "Name")` 는 그대로.
> - `hardhat-gas-reporter` 는 Hardhat 2 전용이라 붙지 않는다. 가스는 테스트 안에서 receipt 로 집계한다 (`test/helpers/gas.ts`).
> - 컨트랙트 소스가 `contracts/contracts/` 가 아니라 `interfaces/` + `src/` + `mocks/` 다 (`hardhat.config.ts` 의 `paths.sources`).

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

`--network localhost` 를 빠뜨리면 스크립트가 바로 멈춘다. 기록 전에 롤 배치, 컨트랙트끼리 가리키는 주소, 세 컨트랙트의 DOMAIN_SEPARATOR 를 다시 계산해 대조하고, 하나라도 틀리면 기록하지 않는다.

서명을 받는 컨트랙트가 셋이라 도메인도 셋이다. 앱은 서명 대상에 맞는 도메인을 골라야 한다: 등록·확정·반려는 `AccountingLedger`, 예산 발행·증액·회수는 `BudgetToken`, 롤 변경은 `RoleManager`.

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
