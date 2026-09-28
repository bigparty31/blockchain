/**
 * 로컬 Hardhat 노드 배포 스크립트.
 *
 *   터미널 1:  npx hardhat node
 *   터미널 2:  npx hardhat run scripts/deploy.ts --network localhost
 *
 * 순서: RoleManager(회장, 총무, 감사) → BudgetToken → AccountingLedger → setLedger.
 * 세 임원은 생성자 인자다. 별도 롤 부여 단계가 없고, 끝난 뒤 배포자는 어떤 권한도 갖지 않는다.
 *
 * 계정 배치 (Hardhat 기본 니모닉의 순서. 개인키는 Hardhat 이 공개한 테스트 키라 파일에 두지 않는다):
 *   [0] deployer   배포자. setLedger 까지만 부르고 잠긴다
 *   [1] president  회장
 *   [2] treasurer  총무
 *   [3] auditor    감사
 *   [4] relayer    서버 릴레이어. 롤 없음
 *
 * 결과는 deployments/<network>.json 과 deployments/abi/*.json 에 쓴다. 백엔드(손종인)가 읽는 파일이다.
 * Amoy 등 외부 네트워크는 이 스크립트 범위가 아니다.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { network } from "hardhat";
import { deployAll } from "./lib/deployAll.ts";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CONTRACTS = ["RoleManager", "BudgetToken", "AccountingLedger"] as const;

const conn = await network.getOrCreate();
const { ethers } = conn;
const networkName = conn.networkName;

const [deployer, president, treasurer, auditor, relayer] = await ethers.getSigners();
const { chainId } = await ethers.provider.getNetwork();

console.log(`network=${networkName} chainId=${chainId}`);
console.log(`deployer=${deployer.address}`);
console.log(`president=${president.address}\ntreasurer=${treasurer.address}\nauditor=${auditor.address}`);
console.log(`relayer=${relayer.address} (롤 없음)`);

const d = await deployAll(
  ethers,
  { president: president.address, treasurer: treasurer.address, auditor: auditor.address },
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
assert(await d.roleManager.hasRole(roles.AUDITOR, auditor.address), "감사 롤 없음");
assert((await d.roleManager.officerCount()) === 3n, "임원 수 != 3");
assert((await d.budgetToken.ledger()) === d.addresses.AccountingLedger, "setLedger 미반영");

const domainSeparator: string = await d.ledger.DOMAIN_SEPARATOR();
const expectedDomain = ethers.TypedDataEncoder.hashDomain({
  name: "AccountingLedger",
  version: "1",
  chainId,
  verifyingContract: d.addresses.AccountingLedger,
});
assert(domainSeparator === expectedDomain, "DOMAIN_SEPARATOR 불일치");

// ---------------------------------------------------------------- ABI 내보내기
const outDir = path.join(ROOT, "deployments");
const abiDir = path.join(outDir, "abi");
await mkdir(abiDir, { recursive: true });

const abiPaths: Record<string, string> = {};
for (const name of CONTRACTS) {
  const artifactPath = path.join(ROOT, "artifacts", "src", `${name}.sol`, `${name}.json`);
  const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
  const rel = path.posix.join("deployments", "abi", `${name}.json`);
  await writeFile(path.join(abiDir, `${name}.json`), JSON.stringify(artifact.abi, null, 2) + "\n", "utf8");
  abiPaths[name] = rel;
}

// ---------------------------------------------------------------- 기록
const latest = await ethers.provider.getBlock("latest");
const record = {
  network: networkName,
  chainId: Number(chainId),
  deployedAt: new Date((latest?.timestamp ?? 0) * 1000).toISOString(),
  solidity: "0.8.28",
  contracts: Object.fromEntries(
    CONTRACTS.map((name) => [
      name,
      {
        address: d.addresses[name],
        deployBlock: d.blocks[name],
        abi: abiPaths[name],
      },
    ]),
  ),
  setLedgerBlock: d.blocks.setLedger,
  eip712: {
    AccountingLedger: {
      name: "AccountingLedger",
      version: "1",
      chainId: Number(chainId),
      verifyingContract: d.addresses.AccountingLedger,
      domainSeparator,
    },
  },
  roles,
  accounts: {
    deployer: deployer.address,
    president: president.address,
    treasurer: treasurer.address,
    auditor: auditor.address,
    relayer: relayer.address,
  },
};

const outFile = path.join(outDir, `${networkName}.json`);
await writeFile(outFile, JSON.stringify(record, null, 2) + "\n", "utf8");

console.log("\n배포 완료");
console.table(
  CONTRACTS.map((name) => ({ contract: name, address: d.addresses[name], block: d.blocks[name] })),
);
console.log(`DOMAIN_SEPARATOR(AccountingLedger) = ${domainSeparator}`);
console.log(`→ ${path.relative(ROOT, outFile)}`);
