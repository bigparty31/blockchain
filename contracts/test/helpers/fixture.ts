import { network } from "hardhat";
import { deployAll } from "../../scripts/lib/deployAll.ts";

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

export const TERM = 20261n;
export const OTHER_TERM = 20262n;

/** docs/CONTRACTS.md category 표 */
export const CATEGORY = {
  행사비: ethers.keccak256(ethers.toUtf8Bytes("행사비")),
  사업비: ethers.keccak256(ethers.toUtf8Bytes("사업비")),
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

// ---------------------------------------------------------------- 픽스처

export async function deployFixture() {
  const [deployer, president, treasurer, auditor, relayer, outsider, extra1, extra2] = await ethers.getSigners();

  const d = await deployAll(
    ethers,
    { president: president.address, treasurer: treasurer.address, auditor: auditor.address },
    deployer,
  );

  return {
    ...d,
    deployer,
    president,
    treasurer,
    auditor,
    relayer,
    outsider,
    extra1,
    extra2,
  };
}

export type Fixture = Awaited<ReturnType<typeof deployFixture>>;

/** 예산 1건 발행까지 끝난 픽스처. budgetId 1 = 행사비 100만원, budgetId 2 = 사업비 50만원. 마감은 30일 뒤. */
export async function budgetFixture() {
  const f = await deployFixture();
  const now = BigInt(await time.latest());
  const expiresAt = now + 30n * 24n * 3600n;
  await f.budgetToken.connect(f.president).issue(1n, TERM, CATEGORY.행사비, 1_000_000n, expiresAt);
  await f.budgetToken.connect(f.president).issue(2n, TERM, CATEGORY.사업비, 500_000n, expiresAt);
  return { ...f, expiresAt };
}

export type BudgetFixture = Awaited<ReturnType<typeof budgetFixture>>;

// ---------------------------------------------------------------- EIP-712

export const TYPES = {
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

export interface ConfirmApproval {
  id: bigint;
  hash: string;
  hadWarning: boolean;
  warningReasonHash: string;
  deadline: bigint;
}

export interface RejectDecision {
  id: bigint;
  reasonHash: string;
  deadline: bigint;
}

export async function domainOf(ledger: any) {
  const { chainId } = await ethers.provider.getNetwork();
  return {
    name: "AccountingLedger",
    version: "1",
    chainId,
    verifyingContract: await ledger.getAddress(),
  };
}

export async function deadlineIn(seconds = 3600): Promise<bigint> {
  return BigInt(await time.latest()) + BigInt(seconds);
}

export async function signRecord(signer: any, ledger: any, req: RecordRequest): Promise<string> {
  return signer.signTypedData(await domainOf(ledger), { RecordRequest: TYPES.RecordRequest }, req);
}

export async function signConfirm(signer: any, ledger: any, approval: ConfirmApproval): Promise<string> {
  return signer.signTypedData(await domainOf(ledger), { ConfirmApproval: TYPES.ConfirmApproval }, approval);
}

export async function signReject(signer: any, ledger: any, decision: RejectDecision): Promise<string> {
  return signer.signTypedData(await domainOf(ledger), { RejectDecision: TYPES.RejectDecision }, decision);
}

// ---------------------------------------------------------------- 요청 빌더

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

/** 총무 서명으로 등록. 릴레이어가 보낸다. */
export async function record(f: Fixture, o: RecordOpts, signer: any = f.treasurer) {
  const req = await makeRecord(o);
  const sig = await signRecord(signer, f.ledger, req);
  return { req, tx: f.ledger.connect(f.relayer).recordPending(req, sig) };
}

export interface ConfirmOpts {
  id: bigint;
  hash?: string;
  hadWarning?: boolean;
  warningReasonHash?: string;
  deadline?: bigint;
}

export async function makeConfirm(o: ConfirmOpts): Promise<ConfirmApproval> {
  return {
    id: o.id,
    hash: o.hash ?? metaHash(o.id.toString()),
    hadWarning: o.hadWarning ?? false,
    warningReasonHash: o.warningReasonHash ?? ZERO32,
    deadline: o.deadline ?? (await deadlineIn()),
  };
}

/** 감사(기본) 서명으로 확정. 릴레이어가 보낸다. */
export async function confirm(f: Fixture, o: ConfirmOpts, signer: any = f.auditor) {
  const approval = await makeConfirm(o);
  const sig = await signConfirm(signer, f.ledger, approval);
  return { approval, tx: f.ledger.connect(f.relayer).confirmEntry(approval, sig) };
}

export interface RejectOpts {
  id: bigint;
  reasonHash?: string;
  deadline?: bigint;
}

export async function makeReject(o: RejectOpts): Promise<RejectDecision> {
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
  const { tx } = await record(f, o);
  await tx;
  const { tx: ctx } = await confirm(f, { id: o.id });
  await ctx;
}
