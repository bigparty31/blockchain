import { network } from "hardhat";
import { deployAll, type DeployOptions } from "../../scripts/lib/deployAll.ts";

export const conn = await network.getOrCreate();
export const { ethers, networkHelpers } = conn;
export const { time, loadFixture } = networkHelpers;

// ---------------------------------------------------------------- 상수

export const ROLE = {
  TREASURER: ethers.keccak256(ethers.toUtf8Bytes("TREASURER")),
  AUDITOR: ethers.keccak256(ethers.toUtf8Bytes("AUDITOR")),
  PRESIDENT: ethers.keccak256(ethers.toUtf8Bytes("PRESIDENT")),
} as const;

export const ZERO32 = ethers.ZeroHash;
export const ZERO_ADDR = ethers.ZeroAddress;

/** 학기 코드 YYYYS (docs/CONTRACTS.md "term") */
export const TERM = 20261n;
export const OTHER_TERM = 20262n;

export const MAX_AMOUNT = 10n ** 15n;
export const U64_MAX = 2n ** 64n - 1n;
export const U32_MAX = 2n ** 32n - 1n;
export const INT256_MIN = -(2n ** 255n);

/** docs/CONTRACTS.md category 표 */
export const CATEGORY = {
  행사비: ethers.keccak256(ethers.toUtf8Bytes("행사비")),
  사업비: ethers.keccak256(ethers.toUtf8Bytes("사업비")),
  운영비: ethers.keccak256(ethers.toUtf8Bytes("운영비")),
  학생회비: ethers.keccak256(ethers.toUtf8Bytes("학생회비")),
} as const;

export const Kind = { INCOME: 0, EXPENSE: 1 } as const;
export const Status = { PENDING: 0, CONFIRMED: 1, REJECTED: 2, BLOCKED: 3 } as const;
export const BlockReason = { BUDGET_EXCEEDED: 0, BUDGET_EXPIRED: 1, BUDGET_NOT_FOUND: 2 } as const;

/** docs/HASHING.md §3 텍스트 해시. 여기서는 정본 문자열이라고 가정한다. */
export function textHash(s: string): string {
  return ethers.sha256(ethers.toUtf8Bytes(s));
}

/** meta_hash 자리. 테스트에서는 값 자체는 중요하지 않고 등록·확정 간 일치만 본다. */
export function metaHash(seed: string): string {
  return ethers.sha256(ethers.toUtf8Bytes(`meta:${seed}`));
}

/** KST 자정 (docs/HASHING.md §1.3). 2026-03-05 00:00 KST = 2026-03-04 15:00 UTC */
export const OCCURRED_AT = 1772636400n;

/** docs/CONTRACTS.md 공통 규칙의 entryCommit 식. 컨트랙트와 독립으로 계산한다. */
export function computeEntryCommit(e: {
  hash: string;
  amount: bigint;
  kind: number | bigint;
  term: bigint;
  budgetId: bigint;
  correctsId: bigint;
  registrant: string;
}): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "int256", "uint8", "uint256", "uint256", "uint256", "address"],
      [e.hash, e.amount, e.kind, e.term, e.budgetId, e.correctsId, e.registrant],
    ),
  );
}

// ---------------------------------------------------------------- 픽스처

export async function deployFixture(opts: DeployOptions = {}) {
  const [deployer, president, treasurer, auditor, relayer, outsider, extra1, extra2] = await ethers.getSigners();

  const d = await deployAll(
    ethers,
    { president: president.address, treasurer: treasurer.address, auditor: auditor.address },
    deployer,
    opts,
  );

  return { ...d, deployer, president, treasurer, auditor, relayer, outsider, extra1, extra2 };
}

export type Fixture = Awaited<ReturnType<typeof deployFixture>>;

/** 원장 자리에 MockLedger 를 넣은 픽스처. BudgetToken 단위 테스트가 spend/refund 를 직접 부른다. */
export async function mockLedgerFixture() {
  return deployFixture({ ledgerContract: "MockLedger" });
}

/** budgetId 1 = 행사비 100만원, budgetId 2 = 사업비 50만원, 둘 다 TERM. 마감은 30일 뒤. */
export async function budgetFixture() {
  const f = await deployFixture();
  const expiresAt = BigInt(await time.latest()) + 30n * 24n * 3600n;
  await (await issueBudget(f, { budgetId: 1n, category: CATEGORY.행사비, amount: 1_000_000n, expiresAt })).tx;
  await (await issueBudget(f, { budgetId: 2n, category: CATEGORY.사업비, amount: 500_000n, expiresAt })).tx;
  return { ...f, expiresAt };
}

export type BudgetFixture = Awaited<ReturnType<typeof budgetFixture>>;

// ---------------------------------------------------------------- EIP-712 공통

async function domainOf(contract: any, name: string) {
  const { chainId } = await ethers.provider.getNetwork();
  return { name, version: "1", chainId, verifyingContract: await contract.getAddress() };
}

export async function deadlineIn(seconds = 3600): Promise<bigint> {
  return BigInt(await time.latest()) + BigInt(seconds);
}

async function sign(signer: any, contract: any, name: string, typeName: string, types: readonly any[], value: any) {
  return signer.signTypedData(await domainOf(contract, name), { [typeName]: types }, value);
}

// ---------------------------------------------------------------- RoleManager

export const ROLE_TYPES = {
  RoleChange: [
    { name: "role", type: "bytes32" },
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export interface RoleChangeOpts {
  role: string;
  from: string;
  to: string;
  nonce?: bigint;
  deadline?: bigint;
}

export async function makeRoleChange(rm: any, o: RoleChangeOpts) {
  return {
    role: o.role,
    from: o.from,
    to: o.to,
    nonce: o.nonce ?? (await rm.nonce()),
    deadline: o.deadline ?? (await deadlineIn()),
  };
}

export async function signRoleChange(signer: any, rm: any, change: any): Promise<string> {
  return sign(signer, rm, "RoleManager", "RoleChange", ROLE_TYPES.RoleChange, change);
}

/** 제안자·승인자 서명으로 롤 변경. 릴레이어가 보낸다. */
export async function changeRole(f: Fixture, o: RoleChangeOpts, proposer: any, approver: any) {
  const change = await makeRoleChange(f.roleManager, o);
  const ps = await signRoleChange(proposer, f.roleManager, change);
  const as = await signRoleChange(approver, f.roleManager, change);
  return { change, tx: f.roleManager.connect(f.relayer).changeRole(change, ps, as) };
}

// ---------------------------------------------------------------- BudgetToken

export const BUDGET_TYPES = {
  IssueRequest: [
    { name: "budgetId", type: "uint256" },
    { name: "term", type: "uint256" },
    { name: "category", type: "bytes32" },
    { name: "amount", type: "uint256" },
    { name: "expiresAt", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  IncreaseRequest: [
    { name: "budgetId", type: "uint256" },
    { name: "amount", type: "uint256" },
    { name: "reasonHash", type: "bytes32" },
    { name: "version", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  ReclaimRequest: [
    { name: "budgetId", type: "uint256" },
    { name: "amount", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export interface IssueOpts {
  budgetId: bigint;
  term?: bigint;
  category: string;
  amount: bigint;
  expiresAt: bigint;
  deadline?: bigint;
}

export async function signIssue(signer: any, bt: any, req: any) {
  return sign(signer, bt, "BudgetToken", "IssueRequest", BUDGET_TYPES.IssueRequest, req);
}

/** 회장 서명(기본)으로 예산 발행. 릴레이어가 보낸다. */
export async function issueBudget(f: Fixture, o: IssueOpts, signer: any = f.president) {
  const req = {
    budgetId: o.budgetId,
    term: o.term ?? TERM,
    category: o.category,
    amount: o.amount,
    expiresAt: o.expiresAt,
    deadline: o.deadline ?? (await deadlineIn()),
  };
  const sig = await signIssue(signer, f.budgetToken, req);
  return { req, tx: f.budgetToken.connect(f.relayer).issue(req, sig) };
}

export interface IncreaseOpts {
  budgetId: bigint;
  amount: bigint;
  reasonHash?: string;
  version?: bigint;
  deadline?: bigint;
}

export async function signIncrease(signer: any, bt: any, req: any) {
  return sign(signer, bt, "BudgetToken", "IncreaseRequest", BUDGET_TYPES.IncreaseRequest, req);
}

/** 회장 요청 + 감사 승인(기본)으로 증액. version 기본값은 현재 version. */
export async function increaseBudget(
  f: Fixture,
  o: IncreaseOpts,
  requester: any = f.president,
  approver: any = f.auditor,
) {
  const req = {
    budgetId: o.budgetId,
    amount: o.amount,
    reasonHash: o.reasonHash ?? textHash("참가 인원 증가"),
    version: o.version ?? BigInt((await f.budgetToken.getBudget(o.budgetId)).version),
    deadline: o.deadline ?? (await deadlineIn()),
  };
  const rs = await signIncrease(requester, f.budgetToken, req);
  const as = await signIncrease(approver, f.budgetToken, req);
  return { req, rs, as, tx: f.budgetToken.connect(f.relayer).increase(req, rs, as) };
}

export interface ReclaimOpts {
  budgetId: bigint;
  amount?: bigint;
  deadline?: bigint;
}

export async function signReclaim(signer: any, bt: any, req: any) {
  return sign(signer, bt, "BudgetToken", "ReclaimRequest", BUDGET_TYPES.ReclaimRequest, req);
}

/** 회장 서명(기본)으로 회수. amount 기본값은 현재 잔량. */
export async function reclaimBudget(f: Fixture, o: ReclaimOpts, signer: any = f.president) {
  const req = {
    budgetId: o.budgetId,
    amount: o.amount ?? (await f.budgetToken.remaining(o.budgetId)),
    deadline: o.deadline ?? (await deadlineIn()),
  };
  const sig = await signReclaim(signer, f.budgetToken, req);
  return { req, sig, tx: f.budgetToken.connect(f.relayer).reclaim(req, sig) };
}

// ---------------------------------------------------------------- AccountingLedger

export const LEDGER_TYPES = {
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
    { name: "reasonHash", type: "bytes32" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export interface RecordRequest {
  id: bigint;
  hash: string;
  amount: bigint;
  kind: number;
  term: bigint;
  occurredAt: bigint;
  budgetId: bigint;
  correctsId: bigint;
  deadline: bigint;
}

export async function signRecord(signer: any, ledger: any, req: RecordRequest): Promise<string> {
  return sign(signer, ledger, "AccountingLedger", "RecordRequest", LEDGER_TYPES.RecordRequest, req);
}

export async function signConfirm(signer: any, ledger: any, approval: any): Promise<string> {
  return sign(signer, ledger, "AccountingLedger", "ConfirmApproval", LEDGER_TYPES.ConfirmApproval, approval);
}

export async function signReject(signer: any, ledger: any, decision: any): Promise<string> {
  return sign(signer, ledger, "AccountingLedger", "RejectDecision", LEDGER_TYPES.RejectDecision, decision);
}

export interface RecordOpts {
  id: bigint;
  amount: bigint;
  kind?: number;
  term?: bigint;
  budgetId?: bigint;
  correctsId?: bigint;
  hash?: string;
  occurredAt?: bigint;
  deadline?: bigint;
}

export async function makeRecord(o: RecordOpts): Promise<RecordRequest> {
  return {
    id: o.id,
    hash: o.hash ?? metaHash(o.id.toString()),
    amount: o.amount,
    kind: o.kind ?? Kind.EXPENSE,
    term: o.term ?? TERM,
    occurredAt: o.occurredAt ?? OCCURRED_AT,
    budgetId: o.budgetId ?? (o.kind === Kind.INCOME ? 0n : 1n),
    correctsId: o.correctsId ?? 0n,
    deadline: o.deadline ?? (await deadlineIn()),
  };
}

/** 총무 서명(기본)으로 등록. 릴레이어가 보낸다. */
export async function record(f: Fixture, o: RecordOpts, signer: any = f.treasurer) {
  const req = await makeRecord(o);
  const sig = await signRecord(signer, f.ledger, req);
  return { req, tx: f.ledger.connect(f.relayer).recordPending(req, sig) };
}

/** 체인에 저장된 항목으로 entryCommit 을 계산한다 (컨트랙트의 entryCommitOf 와 독립). 없는 id 는 0. */
export async function entryCommitFromChain(f: Fixture, id: bigint): Promise<string> {
  const e = await f.ledger.getEntry(id);
  if (e.registrant === ZERO_ADDR) return ZERO32;
  return computeEntryCommit({
    hash: e.hash,
    amount: e.amount,
    kind: e.kind,
    term: e.term,
    budgetId: e.budgetId,
    correctsId: e.correctsId,
    registrant: e.registrant,
  });
}

export interface ConfirmOpts {
  id: bigint;
  hash?: string;
  entryCommit?: string;
  hadWarning?: boolean;
  warningReasonHash?: string;
  deadline?: bigint;
}

export async function makeConfirm(f: Fixture, o: ConfirmOpts) {
  return {
    id: o.id,
    hash: o.hash ?? metaHash(o.id.toString()),
    entryCommit: o.entryCommit ?? (await entryCommitFromChain(f, o.id)),
    hadWarning: o.hadWarning ?? false,
    warningReasonHash: o.warningReasonHash ?? ZERO32,
    deadline: o.deadline ?? (await deadlineIn()),
  };
}

/** 감사 서명(기본)으로 확정. 릴레이어가 보낸다. */
export async function confirm(f: Fixture, o: ConfirmOpts, signer: any = f.auditor) {
  const approval = await makeConfirm(f, o);
  const sig = await signConfirm(signer, f.ledger, approval);
  return { approval, tx: f.ledger.connect(f.relayer).confirmEntry(approval, sig) };
}

export interface RejectOpts {
  id: bigint;
  reasonHash?: string;
  deadline?: bigint;
}

export async function makeReject(o: RejectOpts) {
  return {
    id: o.id,
    reasonHash: o.reasonHash ?? textHash("영수증 미첨부"),
    deadline: o.deadline ?? (await deadlineIn()),
  };
}

export async function reject(f: Fixture, o: RejectOpts, signer: any = f.auditor) {
  const decision = await makeReject(o);
  const sig = await signReject(signer, f.ledger, decision);
  return { decision, tx: f.ledger.connect(f.relayer).rejectEntry(decision, sig) };
}

/** 등록 + 확정을 한 번에. 정상 경로 세팅용. */
export async function recordAndConfirm(f: Fixture, o: RecordOpts) {
  await (await record(f, o)).tx;
  await (await confirm(f, { id: o.id })).tx;
}
