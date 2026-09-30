/**
 * 로컬 Hardhat 노드 배포 스크립트.
 *
 *   터미널 1:  npx hardhat node
 *   터미널 2:  npx hardhat run scripts/deploy.ts --network localhost
 *
 * 순서: RoleManager(회장, 총무, 감사1, 감사2) → BudgetToken → AccountingLedger → setLedger.
 * 네 임원은 생성자 인자다. 별도 롤 부여 단계가 없고, 끝난 뒤 배포자는 어떤 권한도 갖지 않는다.
 *
 * 계정 배치 (Hardhat 기본 니모닉의 순서. 개인키는 Hardhat 이 공개한 테스트 키라 파일에 두지 않는다):
 *   [0] deployer   배포자. setLedger 까지만 부르고 잠긴다
 *   [1] president  회장
 *   [2] treasurer  총무
 *   [3] auditor    감사 1
 *   [4] relayer    서버 릴레이어. 롤 없음 (이전 배치와 같은 번호를 유지한다)
 *   [5] auditor2   감사 2 (감사 최소 2명 — 회장 키 분실 복구용)
 *
 * 결과는 deployments/<network>.json 과 deployments/abi/*.json 에 쓴다. 백엔드(손종인)가 읽는 파일이다.
 * JSON 안의 abi 경로는 그 JSON 파일이 있는 폴더(deployments/) 기준이다.
 * --network 를 빠뜨리면 엉뚱한 이름의 기록 파일이 생기므로 허용한 네트워크 외에는 멈춘다.
 * Amoy 등 외부 네트워크는 이 스크립트 범위가 아니다.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { network } from "hardhat";
import { deployAll } from "./lib/deployAll.ts";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CONTRACTS = ["RoleManager", "BudgetToken", "AccountingLedger"] as const;
const ALLOWED_NETWORKS = ["localhost"];

const conn = await network.getOrCreate();
const { ethers } = conn;
const networkName = conn.networkName;

if (!ALLOWED_NETWORKS.includes(networkName)) {
  throw new Error(
    `배포 대상 네트워크가 "${networkName}" 입니다. --network localhost 로 실행하세요 (허용: ${ALLOWED_NETWORKS.join(", ")}).`,
  );
}

const [deployer, president, treasurer, auditor, relayer, auditor2] = await ethers.getSigners();
const { chainId } = await ethers.provider.getNetwork();

console.log(`network=${networkName} chainId=${chainId}`);
console.log(`deployer=${deployer.address}`);
console.log(`president=${president.address}\ntreasurer=${treasurer.address}`);
console.log(`auditor=${auditor.address}\nauditor2=${auditor2.address}`);
console.log(`relayer=${relayer.address} (롤 없음)`);

const d = await deployAll(
  ethers,
  {
    president: president.address,
    treasurer: treasurer.address,
    auditor1: auditor.address,
    auditor2: auditor2.address,
  },
  deployer,
);

// ---------------------------------------------------------------- 사후 점검
const roles = {
  TREASURER: await d.roleManager.TREASURER(),
  AUDITOR: await d.roleManager.AUDITOR(),
  PRESIDENT: await d.roleManager.PRESIDENT(),
};

function assert(cond: boolean, msg: string) {
  if (!cond) throw new Error(`배포 점검 실패: ${msg}`);
}

for (const who of [deployer, relayer]) {
  assert((await d.roleManager.roleOf(who.address)) === ethers.ZeroHash, `${who.address} 에 롤이 있다`);
}
assert(await d.roleManager.hasRole(roles.PRESIDENT, president.address), "회장 롤 없음");
assert(await d.roleManager.hasRole(roles.TREASURER, treasurer.address), "총무 롤 없음");
assert(await d.roleManager.hasRole(roles.AUDITOR, auditor.address), "감사 1 롤 없음");
assert(await d.roleManager.hasRole(roles.AUDITOR, auditor2.address), "감사 2 롤 없음");
assert((await d.roleManager.holderCount(roles.PRESIDENT)) === 1n, "회장 보유자 수 != 1");
assert((await d.roleManager.holderCount(roles.TREASURER)) === 1n, "총무 보유자 수 != 1");
assert((await d.roleManager.holderCount(roles.AUDITOR)) === 2n, "감사 보유자 수 != 2");

// 서로를 가리키는 주소가 맞는지 (setLedger 도 확인하지만 기록 전에 한 번 더)
assert((await d.budgetToken.ledger()) === d.addresses.AccountingLedger, "BudgetToken.ledger 불일치");
assert((await d.budgetToken.roleManager()) === d.addresses.RoleManager, "BudgetToken.roleManager 불일치");
assert((await d.ledger.roleManager()) === d.addresses.RoleManager, "AccountingLedger.roleManager 불일치");
assert((await d.ledger.budgetToken()) === d.addresses.BudgetToken, "AccountingLedger.budgetToken 불일치");

// EIP-712 도메인: 서명을 받는 세 컨트랙트 모두
const eip712: Record<string, object> = {};
for (const name of CONTRACTS) {
  const contract = name === "RoleManager" ? d.roleManager : name === "BudgetToken" ? d.budgetToken : d.ledger;
  const onchain: string = await contract.DOMAIN_SEPARATOR();
  const expected = ethers.TypedDataEncoder.hashDomain({
    name,
    version: "1",
    chainId,
    verifyingContract: d.addresses[name],
  });
  assert(onchain === expected, `${name} DOMAIN_SEPARATOR 불일치`);
  eip712[name] = { name, version: "1", chainId: Number(chainId), verifyingContract: d.addresses[name], domainSeparator: onchain };
}

// ---------------------------------------------------------------- ABI 내보내기
const outDir = path.join(ROOT, "deployments");
const abiDir = path.join(outDir, "abi");
await mkdir(abiDir, { recursive: true });

const abiPaths: Record<string, string> = {};
const solcVersions = new Set<string>();
for (const name of CONTRACTS) {
  const artifactPath = path.join(ROOT, "artifacts", "src", `${name}.sol`, `${name}.json`);
  const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
  await writeFile(path.join(abiDir, `${name}.json`), JSON.stringify(artifact.abi, null, 2) + "\n", "utf8");
  abiPaths[name] = path.posix.join("abi", `${name}.json`); // deployments/ 기준
  // solc 버전은 하드코딩하지 않고 이 아티팩트를 만든 build-info 에서 읽는다
  const buildInfo = JSON.parse(await readFile(path.join(ROOT, "artifacts", "build-info", `${artifact.buildInfoId}.json`), "utf8"));
  solcVersions.add(buildInfo.solcVersion);
}
assert(solcVersions.size === 1, `컨트랙트마다 solc 버전이 다르다: ${[...solcVersions].join(", ")}`);
const solcVersion = [...solcVersions][0];

// ---------------------------------------------------------------- 기록
const latest = await ethers.provider.getBlock("latest");
const record = {
  network: networkName,
  chainId: Number(chainId),
  deployedAt: new Date((latest?.timestamp ?? 0) * 1000).toISOString(),
  solidity: solcVersion,
  pathBase: "abi 경로는 이 파일이 있는 폴더(contracts/deployments/) 기준",
  contracts: Object.fromEntries(
    CONTRACTS.map((name) => [name, { address: d.addresses[name], deployBlock: d.blocks[name], abi: abiPaths[name] }]),
  ),
  setLedgerBlock: d.blocks.setLedger,
  eip712,
  roles,
  maxAmount: (await d.ledger.MAX_AMOUNT()).toString(),
  recoveryDelaySeconds: Number(await d.roleManager.RECOVERY_DELAY()),
  accounts: {
    deployer: deployer.address,
    president: president.address,
    treasurer: treasurer.address,
    auditor: auditor.address,
    auditor2: auditor2.address,
    relayer: relayer.address,
  },
};

const outFile = path.join(outDir, `${networkName}.json`);
await writeFile(outFile, JSON.stringify(record, null, 2) + "\n", "utf8");

console.log("\n배포 완료");
console.table(CONTRACTS.map((name) => ({ contract: name, address: d.addresses[name], block: d.blocks[name] })));
for (const name of CONTRACTS) {
  console.log(`DOMAIN_SEPARATOR(${name}) = ${(eip712[name] as any).domainSeparator}`);
}
console.log(`→ ${path.relative(ROOT, outFile)}`);
