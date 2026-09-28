import { expect } from "chai";
import {
  ethers,
  time,
  loadFixture,
  budgetFixture,
  type BudgetFixture,
  ROLE,
  ZERO32,
  ZERO_ADDR,
  TERM,
  OTHER_TERM,
  OCCURRED_AT,
  Kind,
  Status,
  BlockReason,
  textHash,
  metaHash,
  record,
  confirm,
  reject,
  recordAndConfirm,
  makeRecord,
  signRecord,
  makeConfirm,
  signConfirm,
  makeReject,
  signReject,
  deadlineIn,
} from "./helpers/fixture.ts";
import { gas } from "./helpers/gas.ts";

/**
 * 총무(treasurer)를 2 인 승인으로 감사 롤로 바꾼다. 한 주소 한 롤이라, "등록자 == 승인자" 는
 * 등록 뒤 롤이 바뀐 경우에만 생길 수 있다. 그 경로를 만든다.
 */
async function turnTreasurerIntoAuditor(f: BudgetFixture) {
  const rm = f.roleManager;
  // 1) 새 총무를 먼저 세운다 (임원 수 유지)
  const id1 = await rm.connect(f.president).proposeRoleChange.staticCall(ROLE.TREASURER, f.treasurer.address, f.extra1.address);
  await rm.connect(f.president).proposeRoleChange(ROLE.TREASURER, f.treasurer.address, f.extra1.address);
  await rm.connect(f.auditor).approveRoleChange(id1);
  // 2) 옛 총무에게 감사 롤을 준다
  const id2 = await rm.connect(f.president).proposeRoleChange.staticCall(ROLE.AUDITOR, ZERO_ADDR, f.treasurer.address);
  await rm.connect(f.president).proposeRoleChange(ROLE.AUDITOR, ZERO_ADDR, f.treasurer.address);
  await rm.connect(f.auditor).approveRoleChange(id2);
  expect(await rm.hasRole(ROLE.AUDITOR, f.treasurer.address)).to.equal(true);
  expect(await rm.hasRole(ROLE.TREASURER, f.treasurer.address)).to.equal(false);
}

describe("AccountingLedger", function () {
  describe("배포", function () {
    it("DOMAIN_SEPARATOR 는 EIP-712 도메인(AccountingLedger, 1, chainId, 주소)과 일치한다", async function () {
      const f = await loadFixture(budgetFixture);
      const { chainId } = await ethers.provider.getNetwork();
      const expected = ethers.TypedDataEncoder.hashDomain({
        name: "AccountingLedger",
        version: "1",
        chainId,
        verifyingContract: f.addresses.AccountingLedger,
      });
      expect(await f.ledger.DOMAIN_SEPARATOR()).to.equal(expected);
    });

    it("필수 테스트 3: 확정 항목을 수정하는 함수가 없다 — 상태 변경 함수는 recordPending·confirmEntry·rejectEntry 뿐", async function () {
      const f = await loadFixture(budgetFixture);
      const mutating = f.ledger.interface.fragments
        .filter((x: any) => x.type === "function" && x.stateMutability !== "view" && x.stateMutability !== "pure")
        .map((x: any) => x.name)
        .sort();
      expect(mutating).to.deep.equal(["confirmEntry", "recordPending", "rejectEntry"]);
    });
  });

  // ------------------------------------------------------------------ 등록

  describe("recordPending — 정상", function () {
    it("지출을 등록하면 PENDING 으로 저장되고 EntryPending 이 난다 (term 포함)", async function () {
      const f = await loadFixture(budgetFixture);
      const { req, tx } = await record(f, { id: 1n, amount: 100_000n });
      await expect(gas("AccountingLedger.recordPending (EXPENSE → PENDING)", tx))
        .to.emit(f.ledger, "EntryPending")
        .withArgs(1n, req.hash, 100_000n, Kind.EXPENSE, TERM, 1n, 0n, f.treasurer.address)
        .and.not.to.emit(f.ledger, "EntryBlocked");

      expect(await f.ledger.exists(1n)).to.equal(true);
      expect(await f.ledger.statusOf(1n)).to.equal(Status.PENDING);
      const e = await f.ledger.getEntry(1n);
      expect(e.hash).to.equal(req.hash);
      expect(e.amount).to.equal(100_000n);
      expect(e.kind).to.equal(Kind.EXPENSE);
      expect(e.status).to.equal(Status.PENDING);
      expect(e.term).to.equal(TERM);
      expect(e.occurredAt).to.equal(OCCURRED_AT);
      expect(e.budgetId).to.equal(1n);
      expect(e.correctsId).to.equal(0n);
      expect(e.registrant).to.equal(f.treasurer.address);
      expect(e.approver).to.equal(ZERO_ADDR);
      // 등록만으로는 예산이 소모되지 않는다
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(0n);
    });

    it("수입은 budgetId 0 으로 등록되고 예산 검사를 받지 않는다", async function () {
      const f = await loadFixture(budgetFixture);
      const { req, tx } = await record(f, { id: 1n, amount: 5_000_000n, kind: Kind.INCOME });
      await expect(gas("AccountingLedger.recordPending (INCOME)", tx))
        .to.emit(f.ledger, "EntryPending")
        .withArgs(1n, req.hash, 5_000_000n, Kind.INCOME, TERM, 0n, 0n, f.treasurer.address);
      expect(await f.ledger.statusOf(1n)).to.equal(Status.PENDING);
    });

    it("없는 id 의 getEntry 는 0 으로 채운 구조체, exists 는 false (백엔드 CHAIN_CLIENT §3)", async function () {
      const f = await loadFixture(budgetFixture);
      expect(await f.ledger.exists(42n)).to.equal(false);
      const e = await f.ledger.getEntry(42n);
      expect(e.hash).to.equal(ZERO32);
      expect(e.amount).to.equal(0n);
      expect(e.registrant).to.equal(ZERO_ADDR);
    });
  });

  describe("recordPending — revert 검사 (등록 순서)", function () {
    it("1 SignatureExpired: deadline 이 지난 서명", async function () {
      const f = await loadFixture(budgetFixture);
      const past = BigInt(await time.latest()) - 1n;
      const { tx } = await record(f, { id: 1n, amount: 1n, deadline: past });
      await expect(tx).to.be.revertedWithCustomError(f.ledger, "SignatureExpired").withArgs(past);
    });

    it("2 EntryAlreadyExists: 같은 id 재등록. id 0 은 예약이라 같은 에러", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      await expect((await record(f, { id: 1n, amount: 2_000n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "EntryAlreadyExists")
        .withArgs(1n);
      await expect((await record(f, { id: 0n, amount: 2_000n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "EntryAlreadyExists")
        .withArgs(0n);
    });

    it("3 TermRequired: term == 0 (수입·지출 공통)", async function () {
      const f = await loadFixture(budgetFixture);
      await expect((await record(f, { id: 1n, amount: 1_000n, term: 0n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "TermRequired")
        .withArgs(1n);
      await expect((await record(f, { id: 2n, amount: 1_000n, term: 0n, kind: Kind.INCOME })).tx)
        .to.be.revertedWithCustomError(f.ledger, "TermRequired")
        .withArgs(2n);
    });

    it("4 ZeroAmount: 금액 0. 차액 0 인 정정도 여기에 걸린다", async function () {
      const f = await loadFixture(budgetFixture);
      await expect((await record(f, { id: 1n, amount: 0n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "ZeroAmount")
        .withArgs(1n);
      await recordAndConfirm(f, { id: 2n, amount: 10_000n });
      await expect((await record(f, { id: 3n, amount: 0n, correctsId: 2n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "ZeroAmount")
        .withArgs(3n);
    });

    it("5 NegativeAmountWithoutCorrection: 정정이 아닌데 음수", async function () {
      const f = await loadFixture(budgetFixture);
      await expect((await record(f, { id: 1n, amount: -1_000n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "NegativeAmountWithoutCorrection")
        .withArgs(1n);
    });

    it("6 InvalidSignature: 서명 바이트가 깨진 경우에만", async function () {
      const f = await loadFixture(budgetFixture);
      const req = await makeRecord({ id: 1n, amount: 1_000n });
      await expect(f.ledger.connect(f.relayer).recordPending(req, "0x1234")).to.be.revertedWithCustomError(
        f.ledger,
        "InvalidSignature",
      );
    });

    it("6 NotRegistrant: 총무가 아닌 서명자 (감사·회장·릴레이어·외부인). 다른 값에 서명한 경우도 여기로 온다", async function () {
      const f = await loadFixture(budgetFixture);
      for (const who of [f.auditor, f.president, f.relayer, f.outsider]) {
        await expect((await record(f, { id: 1n, amount: 1_000n }, who)).tx)
          .to.be.revertedWithCustomError(f.ledger, "NotRegistrant")
          .withArgs(who.address);
      }
      // 총무가 서명했지만 제출된 요청과 다른 값 → 엉뚱한 주소가 복구되어 NotRegistrant
      const signed = await makeRecord({ id: 1n, amount: 1_000n });
      const sig = await signRecord(f.treasurer, f.ledger, signed);
      const tampered = { ...signed, amount: 2_000n };
      await expect(f.ledger.connect(f.relayer).recordPending(tampered, sig)).to.be.revertedWithCustomError(
        f.ledger,
        "NotRegistrant",
      );
    });

    it("7 BudgetIdNotAllowedForIncome: 수입인데 budgetId != 0", async function () {
      const f = await loadFixture(budgetFixture);
      await expect((await record(f, { id: 1n, amount: 1_000n, kind: Kind.INCOME, budgetId: 1n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "BudgetIdNotAllowedForIncome")
        .withArgs(1n, 1n);
    });

    it("8 CorrectionTargetNotFound: 없는 원본", async function () {
      const f = await loadFixture(budgetFixture);
      await expect((await record(f, { id: 1n, amount: -1_000n, correctsId: 99n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "CorrectionTargetNotFound")
        .withArgs(1n, 99n);
    });

    it("8 필수 테스트 4: 정정 대상이 CONFIRMED 가 아니면 revert (PENDING·REJECTED·BLOCKED)", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 10_000n })).tx; // PENDING
      await (await record(f, { id: 2n, amount: 10_000n })).tx;
      await (await reject(f, { id: 2n })).tx; // REJECTED
      await (await record(f, { id: 3n, amount: 2_000_000n })).tx; // BLOCKED (초과)
      expect(await f.ledger.statusOf(3n)).to.equal(Status.BLOCKED);

      for (const target of [1n, 2n, 3n]) {
        await expect((await record(f, { id: 10n + target, amount: -1_000n, correctsId: target })).tx)
          .to.be.revertedWithCustomError(f.ledger, "CorrectionTargetNotConfirmed")
          .withArgs(10n + target, target);
      }
    });

    it("8 CorrectionBudgetMismatch: 음수 정정의 budgetId 가 원본과 다름", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 10_000n, budgetId: 1n });
      await expect((await record(f, { id: 2n, amount: -1_000n, correctsId: 1n, budgetId: 2n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "CorrectionBudgetMismatch")
        .withArgs(2n, 1n, 2n);
    });

    it("9 TermMismatch: 지출 term 이 예산 term 과 다름. 예산 초과보다 먼저 걸린다 (BLOCKED 아님)", async function () {
      const f = await loadFixture(budgetFixture);
      await expect((await record(f, { id: 1n, amount: 1_000n, term: OTHER_TERM })).tx)
        .to.be.revertedWithCustomError(f.ledger, "TermMismatch")
        .withArgs(1n, TERM, OTHER_TERM);
      await expect((await record(f, { id: 2n, amount: 5_000_000n, term: OTHER_TERM })).tx)
        .to.be.revertedWithCustomError(f.ledger, "TermMismatch")
        .withArgs(2n, TERM, OTHER_TERM);
      expect(await f.ledger.exists(1n)).to.equal(false);
      expect(await f.ledger.exists(2n)).to.equal(false);
    });

    it("수입의 term 은 대조할 예산이 없어 서명된 값 그대로 저장된다", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n, kind: Kind.INCOME, term: OTHER_TERM })).tx;
      expect((await f.ledger.getEntry(1n)).term).to.equal(OTHER_TERM);
    });
  });

  describe("recordPending — BLOCKED 저장 (필수 테스트 2 등록 시점)", function () {
    it("잔량 초과는 BLOCKED + EntryBlocked(BUDGET_EXCEEDED). EntryPending 은 나지 않는다", async function () {
      const f = await loadFixture(budgetFixture);
      const { tx } = await record(f, { id: 1n, amount: 1_000_001n });
      await expect(gas("AccountingLedger.recordPending (EXPENSE → BLOCKED)", tx))
        .to.emit(f.ledger, "EntryBlocked")
        .withArgs(1n, 1n, 1_000_001n, BlockReason.BUDGET_EXCEEDED)
        .and.not.to.emit(f.ledger, "EntryPending");
      expect(await f.ledger.statusOf(1n)).to.equal(Status.BLOCKED);
      expect((await f.ledger.getEntry(1n)).registrant).to.equal(f.treasurer.address);
    });

    it("정확히 잔량만큼은 PENDING, 1 원 더는 BLOCKED. 대기 건은 예약되지 않는다", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000_000n })).tx;
      expect(await f.ledger.statusOf(1n)).to.equal(Status.PENDING);
      // 1 번이 대기 중이어도 잔량은 그대로라 2 번도 PENDING
      await (await record(f, { id: 2n, amount: 1_000_000n })).tx;
      expect(await f.ledger.statusOf(2n)).to.equal(Status.PENDING);
    });

    it("마감이 지난 예산은 BLOCKED(BUDGET_EXPIRED)", async function () {
      const f = await loadFixture(budgetFixture);
      await time.increaseTo(f.expiresAt + 1n);
      await expect((await record(f, { id: 1n, amount: 1_000n })).tx)
        .to.emit(f.ledger, "EntryBlocked")
        .withArgs(1n, 1n, 1_000n, BlockReason.BUDGET_EXPIRED);
      expect(await f.ledger.statusOf(1n)).to.equal(Status.BLOCKED);
    });

    it("없는 예산·budgetId 0 지출은 BLOCKED(BUDGET_NOT_FOUND) (백엔드 FakeChainClient 와 동일)", async function () {
      const f = await loadFixture(budgetFixture);
      await expect((await record(f, { id: 1n, amount: 1_000n, budgetId: 99n })).tx)
        .to.emit(f.ledger, "EntryBlocked")
        .withArgs(1n, 99n, 1_000n, BlockReason.BUDGET_NOT_FOUND);
      await expect((await record(f, { id: 2n, amount: 1_000n, budgetId: 0n })).tx)
        .to.emit(f.ledger, "EntryBlocked")
        .withArgs(2n, 0n, 1_000n, BlockReason.BUDGET_NOT_FOUND);
    });

    it("BLOCKED 항목은 확정도 반려도 InvalidStatus(BLOCKED, PENDING)", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 2_000_000n })).tx;
      await expect((await confirm(f, { id: 1n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "InvalidStatus")
        .withArgs(1n, Status.BLOCKED, Status.PENDING);
      await expect((await reject(f, { id: 1n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "InvalidStatus")
        .withArgs(1n, Status.BLOCKED, Status.PENDING);
    });
  });

  // ------------------------------------------------------------------ 확정

  describe("confirmEntry — 정상", function () {
    it("감사가 확정하면 CONFIRMED, BudgetSpent, EntryConfirmed(term 포함), netAmountOf = amount", async function () {
      const f = await loadFixture(budgetFixture);
      const { req, tx: rtx } = await record(f, { id: 1n, amount: 100_000n });
      await rtx;
      const { approval, tx } = await confirm(f, { id: 1n });
      await expect(gas("AccountingLedger.confirmEntry (EXPENSE)", tx))
        .to.emit(f.ledger, "EntryConfirmed")
        .withArgs(1n, req.hash, 100_000n, Kind.EXPENSE, TERM, 1n, false, ZERO32, f.auditor.address)
        .and.to.emit(f.budgetToken, "BudgetSpent")
        .withArgs(1n, 100_000n, 1n);

      expect(approval.hash).to.equal(req.hash);
      expect(await f.ledger.statusOf(1n)).to.equal(Status.CONFIRMED);
      expect((await f.ledger.getEntry(1n)).approver).to.equal(f.auditor.address);
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(100_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(900_000n);
      expect(await f.ledger.netAmountOf(1n)).to.equal(100_000n);
    });

    it("회장도 확정할 수 있다 (감사와 동일 승인 권한)", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      await expect((await confirm(f, { id: 1n }, f.president)).tx).to.emit(f.ledger, "EntryConfirmed");
      expect((await f.ledger.getEntry(1n)).approver).to.equal(f.president.address);
    });

    it("수입 확정은 예산을 건드리지 않는다", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 5_000_000n, kind: Kind.INCOME })).tx;
      await expect(gas("AccountingLedger.confirmEntry (INCOME)", (await confirm(f, { id: 1n })).tx))
        .to.emit(f.ledger, "EntryConfirmed")
        .and.not.to.emit(f.budgetToken, "BudgetSpent");
      expect(await f.ledger.netAmountOf(1n)).to.equal(5_000_000n);
    });

    it("경고 무시 승인: hadWarning 과 사유 해시가 함께 있으면 성공하고 이벤트에 남는다", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      const reason = textHash("OCR 금액 불일치, 영수증 원본 확인함");
      await expect((await confirm(f, { id: 1n, hadWarning: true, warningReasonHash: reason })).tx)
        .to.emit(f.ledger, "EntryConfirmed")
        .withArgs(1n, metaHash("1"), 1_000n, Kind.EXPENSE, TERM, 1n, true, reason, f.auditor.address);
    });
  });

  describe("confirmEntry — revert", function () {
    it("SignatureExpired / EntryNotFound", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      const past = BigInt(await time.latest()) - 1n;
      await expect((await confirm(f, { id: 1n, deadline: past })).tx)
        .to.be.revertedWithCustomError(f.ledger, "SignatureExpired")
        .withArgs(past);
      await expect((await confirm(f, { id: 9n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "EntryNotFound")
        .withArgs(9n);
    });

    it("HashMismatch: 승인자가 본 해시와 저장된 해시가 다름", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      const wrong = metaHash("something-else");
      await expect((await confirm(f, { id: 1n, hash: wrong })).tx)
        .to.be.revertedWithCustomError(f.ledger, "HashMismatch")
        .withArgs(1n, metaHash("1"), wrong);
    });

    it("ReasonRequired: hadWarning 인데 사유 0 / ReasonNotAllowed: 경고 아닌데 사유 있음", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      await expect((await confirm(f, { id: 1n, hadWarning: true, warningReasonHash: ZERO32 })).tx)
        .to.be.revertedWithCustomError(f.ledger, "ReasonRequired")
        .withArgs(1n);
      await expect((await confirm(f, { id: 1n, hadWarning: false, warningReasonHash: textHash("x") })).tx)
        .to.be.revertedWithCustomError(f.ledger, "ReasonNotAllowed")
        .withArgs(1n);
      expect(await f.ledger.statusOf(1n)).to.equal(Status.PENDING);
    });

    it("필수 테스트 7: 릴레이어 키로 승인 불가 (NotApprover). 총무·외부인도 마찬가지", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      for (const who of [f.relayer, f.treasurer, f.outsider, f.deployer]) {
        await expect((await confirm(f, { id: 1n }, who)).tx)
          .to.be.revertedWithCustomError(f.ledger, "NotApprover")
          .withArgs(who.address);
      }
      expect(await f.ledger.statusOf(1n)).to.equal(Status.PENDING);
    });

    it("InvalidSignature: 깨진 서명 바이트", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      const approval = await makeConfirm({ id: 1n });
      await expect(f.ledger.connect(f.relayer).confirmEntry(approval, "0xdead")).to.be.revertedWithCustomError(
        f.ledger,
        "InvalidSignature",
      );
    });

    it("필수 테스트 1: 등록자 == 승인자이면 SelfApproval (등록 뒤 롤이 바뀌어 승인 권한을 얻은 경우)", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx; // treasurer 가 등록
      await turnTreasurerIntoAuditor(f); // 이제 treasurer 주소가 AUDITOR
      await expect((await confirm(f, { id: 1n }, f.treasurer)).tx)
        .to.be.revertedWithCustomError(f.ledger, "SelfApproval")
        .withArgs(1n, f.treasurer.address);
      await expect((await reject(f, { id: 1n }, f.treasurer)).tx)
        .to.be.revertedWithCustomError(f.ledger, "SelfApproval")
        .withArgs(1n, f.treasurer.address);
      // 다른 감사는 확정할 수 있다
      await expect((await confirm(f, { id: 1n }, f.auditor)).tx).to.emit(f.ledger, "EntryConfirmed");
    });

    it("InvalidStatus: 이미 확정·반려된 항목은 다시 확정할 수 없다", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 1_000n });
      await expect((await confirm(f, { id: 1n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "InvalidStatus")
        .withArgs(1n, Status.CONFIRMED, Status.PENDING);
      await (await record(f, { id: 2n, amount: 1_000n })).tx;
      await (await reject(f, { id: 2n })).tx;
      await expect((await confirm(f, { id: 2n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "InvalidStatus")
        .withArgs(2n, Status.REJECTED, Status.PENDING);
    });

    it("필수 테스트 2 (확정 시점): 대기 두 건이 잔량을 나눠 쓰면 나중 확정은 InsufficientBudget 으로 revert, 상태는 PENDING 유지 → 반려 가능", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 600_000n })).tx;
      await (await record(f, { id: 2n, amount: 600_000n })).tx;
      await (await confirm(f, { id: 1n })).tx;
      await expect((await confirm(f, { id: 2n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "InsufficientBudget")
        .withArgs(1n, 400_000n, 600_000n);
      expect(await f.ledger.statusOf(2n)).to.equal(Status.PENDING);
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(600_000n);
      await expect((await reject(f, { id: 2n })).tx).to.emit(f.ledger, "EntryRejected");
    });

    it("필수 테스트 2 (확정 시점): 등록과 확정 사이에 마감이 지나면 BudgetExpired, 상태는 PENDING 유지", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      await time.increaseTo(f.expiresAt + 1n);
      await expect((await confirm(f, { id: 1n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetExpired")
        .withArgs(1n, f.expiresAt);
      expect(await f.ledger.statusOf(1n)).to.equal(Status.PENDING);
    });
  });

  // ------------------------------------------------------------------ 반려

  describe("rejectEntry", function () {
    it("감사가 반려하면 REJECTED, EntryRejected(reasonHash), 예산 영향 없음", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      const reason = textHash("영수증 미첨부 사유가 궁금합니다");
      await expect(gas("AccountingLedger.rejectEntry", (await reject(f, { id: 1n, reasonHash: reason })).tx))
        .to.emit(f.ledger, "EntryRejected")
        .withArgs(1n, reason, f.auditor.address);
      expect(await f.ledger.statusOf(1n)).to.equal(Status.REJECTED);
      expect((await f.ledger.getEntry(1n)).approver).to.equal(f.auditor.address);
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(0n);
    });

    it("ReasonRequired: 반려 사유 해시가 0", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      await expect((await reject(f, { id: 1n, reasonHash: ZERO32 })).tx)
        .to.be.revertedWithCustomError(f.ledger, "ReasonRequired")
        .withArgs(1n);
    });

    it("NotApprover / SignatureExpired / EntryNotFound / InvalidSignature", async function () {
      const f = await loadFixture(budgetFixture);
      await (await record(f, { id: 1n, amount: 1_000n })).tx;
      for (const who of [f.relayer, f.treasurer, f.outsider]) {
        await expect((await reject(f, { id: 1n }, who)).tx)
          .to.be.revertedWithCustomError(f.ledger, "NotApprover")
          .withArgs(who.address);
      }
      const past = BigInt(await time.latest()) - 1n;
      await expect((await reject(f, { id: 1n, deadline: past })).tx).to.be.revertedWithCustomError(
        f.ledger,
        "SignatureExpired",
      );
      await expect((await reject(f, { id: 9n })).tx).to.be.revertedWithCustomError(f.ledger, "EntryNotFound");
      const decision = await makeReject({ id: 1n });
      await expect(f.ledger.connect(f.relayer).rejectEntry(decision, "0x00")).to.be.revertedWithCustomError(
        f.ledger,
        "InvalidSignature",
      );
    });

    it("InvalidStatus: 확정·반려된 항목은 반려할 수 없다", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 1_000n });
      await expect((await reject(f, { id: 1n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "InvalidStatus")
        .withArgs(1n, Status.CONFIRMED, Status.PENDING);
      await (await record(f, { id: 2n, amount: 1_000n })).tx;
      await (await reject(f, { id: 2n })).tx;
      await expect((await reject(f, { id: 2n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "InvalidStatus")
        .withArgs(2n, Status.REJECTED, Status.PENDING);
    });
  });

  // ------------------------------------------------------------------ 정정

  describe("정정", function () {
    it("음수 정정 확정은 원래 예산에 refund 하고 원본 순금액을 줄인다", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 100_000n });
      const { tx } = await record(f, { id: 2n, amount: -30_000n, correctsId: 1n });
      await expect(gas("AccountingLedger.recordPending (음수 정정)", tx))
        .to.emit(f.ledger, "EntryPending")
        .withArgs(2n, metaHash("2"), -30_000n, Kind.EXPENSE, TERM, 1n, 1n, f.treasurer.address);
      await expect(gas("AccountingLedger.confirmEntry (음수 정정 → refund)", (await confirm(f, { id: 2n })).tx))
        .to.emit(f.budgetToken, "BudgetRefunded")
        .withArgs(1n, 30_000n, 2n)
        .and.to.emit(f.ledger, "EntryConfirmed")
        .withArgs(2n, metaHash("2"), -30_000n, Kind.EXPENSE, TERM, 1n, false, ZERO32, f.auditor.address);

      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(70_000n);
      expect(await f.ledger.netAmountOf(1n)).to.equal(70_000n);
      expect(await f.ledger.netAmountOf(2n)).to.equal(0n); // 음수 항목 자체의 순금액은 0
    });

    it("같은 예산 양수 정정 확정은 spend 하고 원본 순금액을 늘린다", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 100_000n });
      await recordAndConfirm(f, { id: 2n, amount: 20_000n, correctsId: 1n });
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(120_000n);
      expect(await f.ledger.netAmountOf(1n)).to.equal(120_000n);
    });

    it("필수 테스트 5: 양수 정정도 잔량 검사 — 등록 시 초과는 BLOCKED, 확정 시 부족은 InsufficientBudget", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 900_000n }); // 잔량 100k
      await expect((await record(f, { id: 2n, amount: 100_001n, correctsId: 1n })).tx)
        .to.emit(f.ledger, "EntryBlocked")
        .withArgs(2n, 1n, 100_001n, BlockReason.BUDGET_EXCEEDED);

      await (await record(f, { id: 3n, amount: 100_000n, correctsId: 1n })).tx; // PENDING
      await (await record(f, { id: 4n, amount: 50_000n })).tx; // 일반 지출도 PENDING
      await (await confirm(f, { id: 4n })).tx; // 잔량 50k
      await expect((await confirm(f, { id: 3n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "InsufficientBudget")
        .withArgs(1n, 50_000n, 100_000n);
      expect(await f.ledger.statusOf(3n)).to.equal(Status.PENDING);
    });

    it("원본별 누적: −6 만 확정 후 −5 만 등록 → CorrectionExceedsOriginal / +3 만(같은 예산) 확정 후 순금액 7 만 → −7 만 허용, −8 만 revert", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 100_000n });
      await recordAndConfirm(f, { id: 2n, amount: -60_000n, correctsId: 1n });
      expect(await f.ledger.netAmountOf(1n)).to.equal(40_000n);

      await expect((await record(f, { id: 3n, amount: -50_000n, correctsId: 1n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "CorrectionExceedsOriginal")
        .withArgs(3n, 1n, 40_000n, 50_000n);

      await recordAndConfirm(f, { id: 4n, amount: 30_000n, correctsId: 1n });
      expect(await f.ledger.netAmountOf(1n)).to.equal(70_000n);

      await expect((await record(f, { id: 5n, amount: -80_000n, correctsId: 1n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "CorrectionExceedsOriginal")
        .withArgs(5n, 1n, 70_000n, 80_000n);
      await recordAndConfirm(f, { id: 6n, amount: -70_000n, correctsId: 1n });
      expect(await f.ledger.netAmountOf(1n)).to.equal(0n);
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(0n);
    });

    it("원본별 누적 (확정 시 최종 검사): 대기 중 음수 정정 두 건이 순금액을 나눠 쓰면 나중 확정은 revert", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 100_000n });
      await (await record(f, { id: 2n, amount: -100_000n, correctsId: 1n })).tx;
      await (await record(f, { id: 3n, amount: -100_000n, correctsId: 1n })).tx; // 등록 시엔 예약 없음
      await (await confirm(f, { id: 2n })).tx;
      await expect((await confirm(f, { id: 3n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "CorrectionExceedsOriginal")
        .withArgs(3n, 1n, 0n, 100_000n);
      expect(await f.ledger.statusOf(3n)).to.equal(Status.PENDING);
    });

    it("RECLASSIFY: 양수(예산 B) 확정 → 음수(예산 A) 확정 → 두 예산 spent 와 원장 잔액이 기대값. 재분류 양수는 원본 순금액에 안 더한다", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 100_000n, budgetId: 1n }); // 원본, 예산 A(1)
      // 서버 규칙: 양수 다음 음수
      await recordAndConfirm(f, { id: 2n, amount: 100_000n, correctsId: 1n, budgetId: 2n }); // 재분류 양수, 예산 B(2)
      expect(await f.ledger.netAmountOf(1n)).to.equal(100_000n); // 다른 예산이라 안 더해짐
      expect((await f.budgetToken.getBudget(2n)).spent).to.equal(100_000n);

      await recordAndConfirm(f, { id: 3n, amount: -100_000n, correctsId: 1n, budgetId: 1n }); // 재분류 음수, 예산 A
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(0n);
      expect((await f.budgetToken.getBudget(2n)).spent).to.equal(100_000n);
      expect(await f.ledger.netAmountOf(1n)).to.equal(0n);

      // 추가 음수 정정(A)은 원본 순금액이 0 이라 revert
      await expect((await record(f, { id: 4n, amount: -1n, correctsId: 1n, budgetId: 1n })).tx)
        .to.be.revertedWithCustomError(f.ledger, "CorrectionExceedsOriginal")
        .withArgs(4n, 1n, 0n, 1n);

      // 장부 잔액 (EntryConfirmed 만, kind 로 나눠서): 지출 합 = 100k + 100k − 100k = 100k
      const logs = await f.ledger.queryFilter(f.ledger.filters.EntryConfirmed());
      let expense = 0n;
      let income = 0n;
      for (const l of logs) {
        if (Number(l.args.kind) === Kind.EXPENSE) expense += BigInt(l.args.amount);
        else income += BigInt(l.args.amount);
      }
      expect(expense).to.equal(100_000n);
      expect(income - expense).to.equal(-100_000n);
    });

    it("한계 우회: 재분류 양수 정정 항목을 원본으로 하는 음수 정정으로 되돌릴 수 있다", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 100_000n, budgetId: 1n });
      await recordAndConfirm(f, { id: 2n, amount: 100_000n, correctsId: 1n, budgetId: 2n });
      expect(await f.ledger.netAmountOf(2n)).to.equal(100_000n);
      await recordAndConfirm(f, { id: 3n, amount: -100_000n, correctsId: 2n, budgetId: 2n });
      expect((await f.budgetToken.getBudget(2n)).spent).to.equal(0n);
      expect(await f.ledger.netAmountOf(2n)).to.equal(0n);
    });

    it("refund 는 마감 뒤에도 된다: 음수 정정은 등록 시 BLOCKED 되지 않고 확정 시 refund 성공", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 100_000n });
      await time.increaseTo(f.expiresAt + 1n);
      await expect((await record(f, { id: 2n, amount: -40_000n, correctsId: 1n })).tx)
        .to.emit(f.ledger, "EntryPending")
        .and.not.to.emit(f.ledger, "EntryBlocked");
      await expect((await confirm(f, { id: 2n })).tx).to.emit(f.budgetToken, "BudgetRefunded").withArgs(1n, 40_000n, 2n);
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(60_000n);
    });

    it("refund 는 회수 뒤에도 된다", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 100_000n });
      await time.increaseTo(f.expiresAt + 1n);
      await f.budgetToken.connect(f.president).reclaim(1n); // issued → 100k
      await recordAndConfirm(f, { id: 2n, amount: -40_000n, correctsId: 1n });
      const b = await f.budgetToken.getBudget(1n);
      expect(b.issued).to.equal(100_000n);
      expect(b.spent).to.equal(60_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(40_000n);
    });

    it("수입도 정정할 수 있고 누적 상한이 같이 적용된다", async function () {
      const f = await loadFixture(budgetFixture);
      await recordAndConfirm(f, { id: 1n, amount: 50_000n, kind: Kind.INCOME });
      await recordAndConfirm(f, { id: 2n, amount: -20_000n, kind: Kind.INCOME, correctsId: 1n, budgetId: 0n });
      expect(await f.ledger.netAmountOf(1n)).to.equal(30_000n);
      await expect(
        (await record(f, { id: 3n, amount: -30_001n, kind: Kind.INCOME, correctsId: 1n, budgetId: 0n })).tx,
      )
        .to.be.revertedWithCustomError(f.ledger, "CorrectionExceedsOriginal")
        .withArgs(3n, 1n, 30_000n, 30_001n);
    });
  });
});
