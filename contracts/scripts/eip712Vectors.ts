/**
 * 백엔드 EIP-712 검증용 서명 벡터 생성 (backend/tests/fixtures/eip712_vectors.json).
 *
 *   node scripts/eip712Vectors.ts
 *
 * 백엔드(app/chain/eip712.py)가 앱과 같은 digest 를 만들고 같은 서명자를 복구하는지 확인하는 기준값이다.
 * 앱의 서명 구현이 아직 없어서, 같은 표준(eth_signTypedData_v4)을 구현한 ethers 로 대신 서명한다.
 * 노드가 필요 없다 — 도메인은 deployments/localhost.json 에서 읽고, 계정은 Hardhat 기본 니모닉에서 유도한다
 * (scripts/deploy.ts 의 계정 배치와 같은 번호. 공개된 테스트 키라 파일에 두지 않는다).
 *
 * 타입과 entryCommit 식은 test/helpers/fixture.ts 의 LEDGER_TYPES·computeEntryCommit 을 옮겨 적은 것이다.
 * fixture.ts 는 맨 위에서 hardhat 네트워크를 띄워서 노드 없이 도는 이 스크립트가 import 할 수 없다.
 * 원장 struct 를 바꾸면 양쪽을 같이 고치고 이 스크립트를 다시 돌린다. 컨트랙트를 재배포해 주소가 바뀌어도 다시 돌린다
 * (backend/tests/test_eip712.py 가 벡터의 도메인과 배포 기록이 다르면 알려준다).
 */
import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { AbiCoder, HDNodeWallet, Mnemonic, TypedDataEncoder, ZeroHash, keccak256, sha256, toUtf8Bytes, version } from "ethers";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DEPLOYMENT = path.join(ROOT, "deployments", "localhost.json");
const OUT = path.resolve(ROOT, "..", "backend", "tests", "fixtures", "eip712_vectors.json");

const HARDHAT_MNEMONIC = "test test test test test test test test test test test junk";

function account(index: number): HDNodeWallet {
  return HDNodeWallet.fromMnemonic(Mnemonic.fromPhrase(HARDHAT_MNEMONIC), `m/44'/60'/0'/0/${index}`);
}

const treasurer = account(2);
const auditor = account(3);

// test/helpers/fixture.ts LEDGER_TYPES 와 같다 (docs/CONTRACTS.md EIP-712 표)
const TYPES = {
  RecordRequest: [
    { name: "id", type: "uint256" },
    { name: "hash", type: "bytes32" },
    { name: "amount", type: "int256" },
    { name: "kind", type: "uint8" },
    { name: "term", type: "uint256" },
    { name: "occurredAt", type: "uint256" },
    { name: "budgetId", type: "uint256" },
    { name: "correctsId", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  ConfirmApproval: [
    { name: "id", type: "uint256" },
    { name: "hash", type: "bytes32" },
    { name: "entryCommit", type: "bytes32" },
    { name: "hadWarning", type: "bool" },
    { name: "warningReasonHash", type: "bytes32" },
    { name: "deadline", type: "uint256" },
  ],
  RejectDecision: [
    { name: "id", type: "uint256" },
    { name: "entryCommit", type: "bytes32" },
    { name: "reasonHash", type: "bytes32" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

const INCOME = 0;
const EXPENSE = 1;
const TERM = 20262n;
const OCCURRED_AT = 1790694000n; // 2026-09-30 00:00 KST (docs/HASHING.md §1.3: % 86400 == 54000)
const DEADLINE = 1790700000n; // 서명 시한. 서명 대상의 한 필드라 바꾸면 digest 와 복구되는 서명자가 모두 바뀐다

function computeEntryCommit(e: {
  hash: string;
  amount: bigint;
  kind: number;
  term: bigint;
  occurredAt: bigint;
  budgetId: bigint;
  correctsId: bigint;
  registrant: string;
}): string {
  return keccak256(
    AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "int256", "uint8", "uint256", "uint256", "uint256", "uint256", "address"],
      [e.hash, e.amount, e.kind, e.term, e.occurredAt, e.budgetId, e.correctsId, e.registrant],
    ),
  );
}

const deployment = JSON.parse(await readFile(DEPLOYMENT, "utf8"));
const d = deployment.eip712.AccountingLedger;
const domain = { name: d.name, version: d.version, chainId: BigInt(d.chainId), verifyingContract: d.verifyingContract };

if (TypedDataEncoder.hashDomain(domain) !== d.domainSeparator.toLowerCase()) {
  throw new Error("배포 기록의 domainSeparator 가 도메인 네 필드로 계산한 값과 다르다");
}

const expense = {
  id: 2n,
  hash: sha256(toUtf8Bytes("vector:expense")),
  amount: 35000n,
  kind: EXPENSE,
  term: TERM,
  occurredAt: OCCURRED_AT,
  budgetId: 1n,
  correctsId: 0n,
  deadline: DEADLINE,
};

const cases: { name: string; primaryType: keyof typeof TYPES; signer: HDNodeWallet; message: Record<string, unknown> }[] = [
  {
    name: "record_income",
    primaryType: "RecordRequest",
    signer: treasurer,
    message: {
      id: 1n,
      hash: sha256(toUtf8Bytes("vector:income")),
      amount: 500000n,
      kind: INCOME,
      term: TERM,
      occurredAt: OCCURRED_AT,
      budgetId: 0n,
      correctsId: 0n,
      deadline: DEADLINE,
    },
  },
  { name: "record_expense", primaryType: "RecordRequest", signer: treasurer, message: expense },
  {
    // int256 음수 인코딩 확인용 (정정 항목만 음수)
    name: "record_negative_correction",
    primaryType: "RecordRequest",
    signer: treasurer,
    message: { ...expense, id: 3n, hash: sha256(toUtf8Bytes("vector:refund")), amount: -20000n, correctsId: 2n },
  },
  {
    name: "confirm_expense",
    primaryType: "ConfirmApproval",
    signer: auditor,
    message: {
      id: expense.id,
      hash: expense.hash,
      entryCommit: computeEntryCommit({ ...expense, registrant: treasurer.address }),
      hadWarning: false,
      warningReasonHash: ZeroHash,
      deadline: DEADLINE,
    },
  },
  {
    // bool true · 사유 해시 인코딩 확인용
    name: "confirm_with_warning",
    primaryType: "ConfirmApproval",
    signer: auditor,
    message: {
      id: expense.id,
      hash: expense.hash,
      entryCommit: computeEntryCommit({ ...expense, registrant: treasurer.address }),
      hadWarning: true,
      warningReasonHash: sha256(toUtf8Bytes("vector:warning-reason")),
      deadline: DEADLINE,
    },
  },
  {
    name: "reject_expense",
    primaryType: "RejectDecision",
    signer: auditor,
    message: {
      id: expense.id,
      entryCommit: computeEntryCommit({ ...expense, registrant: treasurer.address }),
      reasonHash: sha256(toUtf8Bytes("vector:reject-reason")),
      deadline: DEADLINE,
    },
  },
];

// JSON 에는 bigint 를 넣을 수 없어 숫자로 적는다. 2^53 을 넘으면 반올림돼 서명한 값과 달라지므로 멈춘다
function plain(m: Record<string, unknown>) {
  return Object.fromEntries(
    Object.entries(m).map(([k, v]) => {
      if (typeof v !== "bigint") return [k, v];
      if (!Number.isSafeInteger(Number(v))) throw new Error(`${k} = ${v} 는 JSON 숫자로 정확히 적을 수 없다`);
      return [k, Number(v)];
    }),
  );
}

const vectors = [];
for (const c of cases) {
  const types = { [c.primaryType]: [...TYPES[c.primaryType]] }; // ethers 는 readonly 배열을 받지 않는다
  const signature = await c.signer.signTypedData(domain, types, c.message);
  vectors.push({
    name: c.name,
    primaryType: c.primaryType,
    message: plain(c.message),
    digest: TypedDataEncoder.hash(domain, types, c.message),
    signature,
    signer: c.signer.address,
  });
}

const out = {
  generatedBy: `contracts/scripts/eip712Vectors.ts (ethers ${version})`,
  domain: { ...domain, chainId: Number(domain.chainId), domainSeparator: d.domainSeparator.toLowerCase() },
  vectors,
};

await mkdir(path.dirname(OUT), { recursive: true });
await writeFile(OUT, JSON.stringify(out, null, 2) + "\n");
console.log(`${vectors.length}개 벡터 → ${path.relative(path.resolve(ROOT, ".."), OUT)}`);
