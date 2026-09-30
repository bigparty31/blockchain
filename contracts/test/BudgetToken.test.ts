import { expect } from "chai";
import {
  ethers,
  time,
  loadFixture,
  deployFixture,
  mockLedgerFixture,
  type Fixture,
  CATEGORY,
  TERM,
  OTHER_TERM,
  ZERO32,
  ZERO_ADDR,
  MAX_AMOUNT,
  U64_MAX,
  U32_MAX,
  textHash,
  issueBudget,
  increaseBudget,
  reclaimBudget,
  signIssue,
  signIncrease,
  deadlineIn,
} from "./helpers/fixture.ts";
import { gas } from "./helpers/gas.ts";

const DAY = 24n * 3600n;

/**
 * BudgetToken 단위 픽스처. deployAll 의 배포 순서를 그대로 쓰되 원장 자리에 MockLedger 를 넣는다.
 * f.ledger.spend / refund 를 부르면 MockLedger 가 BudgetToken 을 호출한다 (msg.sender = 원장).
 * 예산 1 = 행사비 10만원, 마감 30일 뒤.
 */
async function unitFixture() {
  const f = await mockLedgerFixture();
  const expiresAt = BigInt(await time.latest()) + 30n * DAY;
  await (await issueBudget(f, { budgetId: 1n, category: CATEGORY.행사비, amount: 100_000n, expiresAt })).tx;
  return { ...f, expiresAt };
}

type Unit = Awaited<ReturnType<typeof unitFixture>>;

async function assertInvariant(f: Fixture, budgetId: bigint) {
  const b = await f.budgetToken.getBudget(budgetId);
  expect(b.spent <= b.issued, `spent(${b.spent}) <= issued(${b.issued})`).to.equal(true);
  expect(await f.budgetToken.remaining(budgetId)).to.equal(b.issued - b.spent);
}

async function spend(f: Unit, amount: bigint, entryId = 11n, budgetId = 1n) {
  return f.ledger.spend(budgetId, amount, entryId);
}

async function refund(f: Unit, amount: bigint, entryId = 12n, budgetId = 1n) {
  return f.ledger.refund(budgetId, amount, entryId);
}

describe("BudgetToken", function () {
  describe("setLedger (배포자 1회)", function () {
    it("배포 직후 원장 주소가 설정되어 있고 LedgerSet 이 한 번 났다", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.budgetToken.ledger()).to.equal(f.addresses.AccountingLedger);
      expect(await f.budgetToken.roleManager()).to.equal(f.addresses.RoleManager);
      const logs = await f.budgetToken.queryFilter(f.budgetToken.filters.LedgerSet());
      expect(logs.length).to.equal(1);
      expect(logs[0].args.ledger).to.equal(f.addresses.AccountingLedger);
    });

    it("두 번째 호출은 LedgerAlreadySet (배포자여도)", async function () {
      const f = await loadFixture(deployFixture);
      await expect(f.budgetToken.connect(f.deployer).setLedger(f.outsider.address))
        .to.be.revertedWithCustomError(f.budgetToken, "LedgerAlreadySet")
        .withArgs(f.addresses.AccountingLedger);
    });

    it("배포자가 아니면 Unauthorized, 0 주소는 ZeroAddress, 다른 BudgetToken 을 가리키는 원장은 LedgerMismatch", async function () {
      const [deployer, p, t, a, outsider, a2] = await ethers.getSigners();
      const rm = await ethers.deployContract("RoleManager", [p.address, t.address, a.address, a2.address], deployer);
      const bt = await ethers.deployContract("BudgetToken", [await rm.getAddress()], deployer);
      const otherBt = await ethers.deployContract("BudgetToken", [await rm.getAddress()], deployer);
      const wrong = await ethers.deployContract("MockLedger", [await rm.getAddress(), await otherBt.getAddress()], deployer);
      const wrongRm = await ethers.deployContract("MockLedger", [outsider.address, await bt.getAddress()], deployer);
      const right = await ethers.deployContract("MockLedger", [await rm.getAddress(), await bt.getAddress()], deployer);
      expect(await bt.ledger()).to.equal(ZERO_ADDR);

      await expect(bt.connect(outsider).setLedger(await right.getAddress()))
        .to.be.revertedWithCustomError(bt, "Unauthorized")
        .withArgs(outsider.address);
      await expect(bt.connect(deployer).setLedger(ZERO_ADDR)).to.be.revertedWithCustomError(bt, "ZeroAddress");
      await expect(bt.connect(deployer).setLedger(await wrong.getAddress()))
        .to.be.revertedWithCustomError(bt, "LedgerMismatch")
        .withArgs(await wrong.getAddress());
      await expect(bt.connect(deployer).setLedger(await wrongRm.getAddress()))
        .to.be.revertedWithCustomError(bt, "LedgerMismatch")
        .withArgs(await wrongRm.getAddress());
      // 코드가 없는 주소도 받지 않는다 (roleManager() 호출이 실패)
      await expect(bt.connect(deployer).setLedger(outsider.address)).to.be.revert(ethers);

      await expect(bt.connect(deployer).setLedger(await right.getAddress()))
        .to.emit(bt, "LedgerSet")
        .withArgs(await right.getAddress());
    });
  });

  describe("issue (회장 서명)", function () {
    it("회장이 서명하면 version 1, issued = amount, BudgetIssued(actor = 회장)", async function () {
      const f = await loadFixture(unitFixture);
      const { tx } = await issueBudget(f, { budgetId: 2n, category: CATEGORY.사업비, amount: 50_000n, expiresAt: f.expiresAt });
      await expect(gas("BudgetToken.issue", tx))
        .to.emit(f.budgetToken, "BudgetIssued")
        .withArgs(2n, TERM, CATEGORY.사업비, 50_000n, f.expiresAt, f.president.address);

      const b = await f.budgetToken.getBudget(2n);
      expect(b.term).to.equal(TERM);
      expect(b.category).to.equal(CATEGORY.사업비);
      expect(b.issued).to.equal(50_000n);
      expect(b.spent).to.equal(0n);
      expect(b.expiresAt).to.equal(f.expiresAt);
      expect(b.version).to.equal(1n);
      expect(await f.budgetToken.remaining(2n)).to.equal(50_000n);
      expect(await f.budgetToken.exists(2n)).to.equal(true);
      expect(await f.budgetToken.exists(3n)).to.equal(false);
      expect(await f.budgetToken.budgetIdOf(TERM, CATEGORY.사업비)).to.equal(2n);
      expect(await f.budgetToken.budgetIdOf(OTHER_TERM, CATEGORY.사업비)).to.equal(0n);
    });

    it("회장이 아닌 서명은 NotPresident (감사·총무·릴레이어·배포자)", async function () {
      const f = await loadFixture(unitFixture);
      for (const who of [f.auditor, f.treasurer, f.relayer, f.deployer]) {
        await expect((await issueBudget(f, { budgetId: 2n, category: CATEGORY.사업비, amount: 1n, expiresAt: f.expiresAt }, who)).tx)
          .to.be.revertedWithCustomError(f.budgetToken, "NotPresident")
          .withArgs(who.address);
      }
    });

    it("SignatureExpired / InvalidSignature", async function () {
      const f = await loadFixture(unitFixture);
      const past = BigInt(await time.latest()) - 1n;
      await expect((await issueBudget(f, { budgetId: 2n, category: CATEGORY.사업비, amount: 1n, expiresAt: f.expiresAt, deadline: past })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "SignatureExpired")
        .withArgs(past);
      const req = { budgetId: 2n, term: TERM, category: CATEGORY.사업비, amount: 1n, expiresAt: f.expiresAt, deadline: await deadlineIn() };
      await expect(f.budgetToken.connect(f.relayer).issue(req, "0x00")).to.be.revertedWithCustomError(
        f.budgetToken,
        "InvalidSignature",
      );
      // 회장이 서명한 값과 다른 값을 제출하면 엉뚱한 주소가 복구되어 NotPresident
      const sig = await signIssue(f.president, f.budgetToken, req);
      await expect(f.budgetToken.connect(f.relayer).issue({ ...req, amount: 2n }, sig)).to.be.revertedWithCustomError(
        f.budgetToken,
        "NotPresident",
      );
    });

    it("같은 (term, category) 두 번째 발행은 BudgetAlreadyIssued. 다른 학기는 된다", async function () {
      const f = await loadFixture(unitFixture);
      await expect((await issueBudget(f, { budgetId: 2n, category: CATEGORY.행사비, amount: 1n, expiresAt: f.expiresAt })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetAlreadyIssued")
        .withArgs(TERM, CATEGORY.행사비, 1n);
      await expect((await issueBudget(f, { budgetId: 2n, term: OTHER_TERM, category: CATEGORY.행사비, amount: 1n, expiresAt: f.expiresAt })).tx)
        .to.emit(f.budgetToken, "BudgetIssued");
    });

    it("회수된 뒤에도 같은 (term, category) 는 다시 발행할 수 없다", async function () {
      const f = await loadFixture(unitFixture);
      await time.increaseTo(f.expiresAt + 1n);
      await (await reclaimBudget(f, { budgetId: 1n })).tx;
      const later = BigInt(await time.latest()) + 30n * DAY;
      await expect((await issueBudget(f, { budgetId: 2n, category: CATEGORY.행사비, amount: 1n, expiresAt: later })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetAlreadyIssued")
        .withArgs(TERM, CATEGORY.행사비, 1n);
    });

    it("입력 검사: ReservedId / BudgetAlreadyExists / TermRequired / ZeroAmount / AmountOutOfRange / BudgetExpired / FieldOutOfRange", async function () {
      const f = await loadFixture(unitFixture);
      const c = CATEGORY.운영비;
      const ok = { budgetId: 2n, category: c, amount: 1n, expiresAt: f.expiresAt };
      await expect((await issueBudget(f, { ...ok, budgetId: 0n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "ReservedId")
        .withArgs(0n);
      await expect((await issueBudget(f, { ...ok, budgetId: 1n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetAlreadyExists")
        .withArgs(1n);
      await expect((await issueBudget(f, { ...ok, term: 0n })).tx).to.be.revertedWithCustomError(f.budgetToken, "TermRequired");
      await expect((await issueBudget(f, { ...ok, amount: 0n })).tx).to.be.revertedWithCustomError(f.budgetToken, "ZeroAmount");
      await expect((await issueBudget(f, { ...ok, amount: MAX_AMOUNT + 1n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "AmountOutOfRange")
        .withArgs(MAX_AMOUNT + 1n);
      const past = BigInt(await time.latest()) - 1n;
      await expect((await issueBudget(f, { ...ok, expiresAt: past })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetExpired")
        .withArgs(2n, past);
      await expect((await issueBudget(f, { ...ok, budgetId: U64_MAX + 1n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "FieldOutOfRange")
        .withArgs(U64_MAX + 1n);
      await expect((await issueBudget(f, { ...ok, term: U32_MAX + 1n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "FieldOutOfRange")
        .withArgs(U32_MAX + 1n);
      await expect((await issueBudget(f, { ...ok, expiresAt: U64_MAX + 1n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "FieldOutOfRange")
        .withArgs(U64_MAX + 1n);
      await expect((await issueBudget(f, { ...ok, amount: MAX_AMOUNT })).tx).to.emit(f.budgetToken, "BudgetIssued");
    });
  });

  describe("increase (회장 요청 + 감사 승인)", function () {
    it("증액하면 issued 가 더해지고 version 이 오르며 BudgetIncreased 에 사유·요청자·승인자가 남는다", async function () {
      const f = await loadFixture(unitFixture);
      const reason = textHash("행사 규모 확대");
      const { tx } = await increaseBudget(f, { budgetId: 1n, amount: 20_000n, reasonHash: reason });
      await expect(gas("BudgetToken.increase", tx))
        .to.emit(f.budgetToken, "BudgetIncreased")
        .withArgs(1n, 20_000n, 2n, reason, f.president.address, f.auditor.address);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.issued).to.equal(120_000n);
      expect(b.version).to.equal(2n);

      await (await increaseBudget(f, { budgetId: 1n, amount: 5_000n })).tx;
      expect((await f.budgetToken.getBudget(1n)).version).to.equal(3n);
      expect((await f.budgetToken.getBudget(1n)).issued).to.equal(125_000n);
    });

    it("감사 승인 없이는 안 된다: 요청자가 회장이 아니면 NotPresident, 승인자가 감사가 아니면 NotAuditor", async function () {
      const f = await loadFixture(unitFixture);
      // 회장 혼자 (승인 자리도 회장)
      await expect((await increaseBudget(f, { budgetId: 1n, amount: 1n }, f.president, f.president)).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "NotAuditor")
        .withArgs(f.president.address);
      for (const who of [f.treasurer, f.relayer, f.outsider]) {
        await expect((await increaseBudget(f, { budgetId: 1n, amount: 1n }, f.president, who)).tx)
          .to.be.revertedWithCustomError(f.budgetToken, "NotAuditor")
          .withArgs(who.address);
      }
      // 감사가 요청하고 회장이 승인하는 역순도 안 된다
      await expect((await increaseBudget(f, { budgetId: 1n, amount: 1n }, f.auditor, f.president)).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "NotPresident")
        .withArgs(f.auditor.address);
      expect((await f.budgetToken.getBudget(1n)).issued).to.equal(100_000n);
    });

    it("같은 서명을 두 번 쓰면 VersionMismatch", async function () {
      const f = await loadFixture(unitFixture);
      const first = await increaseBudget(f, { budgetId: 1n, amount: 1_000n });
      await first.tx;
      await expect(f.budgetToken.connect(f.relayer).increase(first.req, first.rs, first.as))
        .to.be.revertedWithCustomError(f.budgetToken, "VersionMismatch")
        .withArgs(1n, 2n, 1n);
    });

    it("사유 해시 0 은 ReasonRequired, 0 원은 ZeroAmount, 없는 예산은 BudgetNotFound", async function () {
      const f = await loadFixture(unitFixture);
      await expect((await increaseBudget(f, { budgetId: 1n, amount: 1n, reasonHash: ZERO32 })).tx).to.be.revertedWithCustomError(
        f.budgetToken,
        "ReasonRequired",
      );
      await expect((await increaseBudget(f, { budgetId: 1n, amount: 0n })).tx).to.be.revertedWithCustomError(
        f.budgetToken,
        "ZeroAmount",
      );
      await expect((await increaseBudget(f, { budgetId: 9n, amount: 1n, version: 0n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetNotFound")
        .withArgs(9n);
    });

    it("증액 후 한도가 MAX_AMOUNT 를 넘으면 AmountOutOfRange", async function () {
      const f = await loadFixture(unitFixture);
      await expect((await increaseBudget(f, { budgetId: 1n, amount: MAX_AMOUNT })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "AmountOutOfRange")
        .withArgs(MAX_AMOUNT + 100_000n);
    });

    it("마감이 지난 예산은 증액할 수 없다 (BudgetExpired)", async function () {
      const f = await loadFixture(unitFixture);
      await time.increaseTo(f.expiresAt + 1n);
      await expect((await increaseBudget(f, { budgetId: 1n, amount: 1n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetExpired")
        .withArgs(1n, f.expiresAt);
    });

    it("SignatureExpired / InvalidSignature", async function () {
      const f = await loadFixture(unitFixture);
      const past = BigInt(await time.latest()) - 1n;
      await expect((await increaseBudget(f, { budgetId: 1n, amount: 1n, deadline: past })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "SignatureExpired")
        .withArgs(past);
      const req = { budgetId: 1n, amount: 1n, reasonHash: textHash("x"), version: 1n, deadline: await deadlineIn() };
      const rs = await signIncrease(f.president, f.budgetToken, req);
      await expect(f.budgetToken.connect(f.relayer).increase(req, rs, "0xdead")).to.be.revertedWithCustomError(
        f.budgetToken,
        "InvalidSignature",
      );
    });

    it("감액 함수는 ABI 에 없다 (이름마다 따로 검사 — 2차 리뷰 N8)", async function () {
      const f = await loadFixture(unitFixture);
      const names: string[] = f.budgetToken.interface.fragments
        .filter((x: any) => x.type === "function")
        .map((x: any) => x.name);
      for (const forbidden of ["decrease", "reduce", "setIssued", "setAllocated", "setSpent", "setBudget"]) {
        expect(names, forbidden).to.not.include(forbidden);
      }
      // 한도를 바꾸는 상태 변경 함수는 increase 와 reclaim(마감 뒤 잔량 회수)뿐이다
      const mutating = f.budgetToken.interface.fragments
        .filter((x: any) => x.type === "function" && x.stateMutability !== "view" && x.stateMutability !== "pure")
        .map((x: any) => x.name)
        .sort();
      expect(mutating).to.deep.equal(["increase", "issue", "reclaim", "refund", "setLedger", "spend"]);
    });
  });

  describe("spend — 필수 테스트 8: 원장 외 호출자는 revert", function () {
    it("원장이 아닌 계정의 spend·refund 는 Unauthorized (회장·배포자·외부인 모두)", async function () {
      const f = await loadFixture(unitFixture);
      for (const who of [f.president, f.deployer, f.outsider, f.treasurer, f.relayer]) {
        await expect(f.budgetToken.connect(who).spend(1n, 1n, 1n))
          .to.be.revertedWithCustomError(f.budgetToken, "Unauthorized")
          .withArgs(who.address);
        await expect(f.budgetToken.connect(who).refund(1n, 1n, 1n))
          .to.be.revertedWithCustomError(f.budgetToken, "Unauthorized")
          .withArgs(who.address);
      }
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(0n);
    });

    it("원장이 부르면 spent 가 오르고 BudgetSpent 가 난다", async function () {
      const f = await loadFixture(unitFixture);
      await expect(gas("BudgetToken.spend", spend(f, 30_000n)))
        .to.emit(f.budgetToken, "BudgetSpent")
        .withArgs(1n, 30_000n, 11n);
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(30_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(70_000n);
      await assertInvariant(f, 1n);
    });

    it("잔량을 넘으면 InsufficientBudget(budgetId, remaining, requested), 딱 잔량은 된다", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 30_000n);
      await expect(spend(f, 70_001n, 12n))
        .to.be.revertedWithCustomError(f.budgetToken, "InsufficientBudget")
        .withArgs(1n, 70_000n, 70_001n);
      await expect(spend(f, 70_000n, 12n)).to.not.be.revert(ethers);
      expect(await f.budgetToken.remaining(1n)).to.equal(0n);
    });

    it("없는 예산·0 원은 revert", async function () {
      const f = await loadFixture(unitFixture);
      await expect(spend(f, 1n, 1n, 9n)).to.be.revertedWithCustomError(f.budgetToken, "BudgetNotFound").withArgs(9n);
      await expect(spend(f, 0n)).to.be.revertedWithCustomError(f.budgetToken, "ZeroAmount");
    });

    it("마감이 지나면 BudgetExpired", async function () {
      const f = await loadFixture(unitFixture);
      await time.increaseTo(f.expiresAt + 1n);
      await expect(spend(f, 1n)).to.be.revertedWithCustomError(f.budgetToken, "BudgetExpired").withArgs(1n, f.expiresAt);
    });
  });

  describe("refund — 마감·회수와 무관하게 소모액 범위 안에서 항상 성공", function () {
    it("refund 는 spent 만 줄이고 BudgetRefunded 를 낸다", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 30_000n);
      await expect(gas("BudgetToken.refund", refund(f, 10_000n)))
        .to.emit(f.budgetToken, "BudgetRefunded")
        .withArgs(1n, 10_000n, 12n);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.spent).to.equal(20_000n);
      expect(b.issued).to.equal(100_000n);
      await assertInvariant(f, 1n);
    });

    it("소모액을 넘는 refund 는 RefundExceedsSpent, 0 원은 ZeroAmount", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 30_000n);
      await expect(refund(f, 30_001n))
        .to.be.revertedWithCustomError(f.budgetToken, "RefundExceedsSpent")
        .withArgs(1n, 30_000n, 30_001n);
      await expect(refund(f, 0n)).to.be.revertedWithCustomError(f.budgetToken, "ZeroAmount");
    });

    it("마감 뒤에도 refund 는 성공한다", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 30_000n);
      await time.increaseTo(f.expiresAt + 1n);
      await expect(refund(f, 30_000n)).to.not.be.revert(ethers);
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(0n);
      await assertInvariant(f, 1n);
    });

    it("회수 → refund → spend 시도 → revert. 다시 회수하면 된다", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 60_000n);
      await time.increaseTo(f.expiresAt + 1n);
      await (await reclaimBudget(f, { budgetId: 1n })).tx; // issued 100k → 60k
      expect(await f.budgetToken.remaining(1n)).to.equal(0n);

      await expect(refund(f, 20_000n)).to.not.be.revert(ethers);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.issued).to.equal(60_000n);
      expect(b.spent).to.equal(40_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(20_000n);
      await assertInvariant(f, 1n);

      await expect(spend(f, 10_000n, 13n)).to.be.revertedWithCustomError(f.budgetToken, "BudgetExpired").withArgs(1n, f.expiresAt);

      await expect((await reclaimBudget(f, { budgetId: 1n })).tx)
        .to.emit(f.budgetToken, "BudgetReclaimed")
        .withArgs(1n, 20_000n, f.president.address);
      expect((await f.budgetToken.getBudget(1n)).issued).to.equal(40_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(0n);
    });

    it("증액 후 refund → remaining 이 issued 를 넘지 않는다", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 80_000n);
      await (await increaseBudget(f, { budgetId: 1n, amount: 50_000n })).tx; // issued 150k
      await refund(f, 80_000n);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.issued).to.equal(150_000n);
      expect(b.spent).to.equal(0n);
      expect(await f.budgetToken.remaining(1n)).to.equal(150_000n);
      await assertInvariant(f, 1n);
      await expect(refund(f, 1n, 13n)).to.be.revertedWithCustomError(f.budgetToken, "RefundExceedsSpent");
    });
  });

  describe("reclaim (회장 서명, 마감 뒤에만, 재호출 가능)", function () {
    it("회장이 아닌 서명은 NotPresident", async function () {
      const f = await loadFixture(unitFixture);
      await time.increaseTo(f.expiresAt + 1n);
      await expect((await reclaimBudget(f, { budgetId: 1n }, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "NotPresident")
        .withArgs(f.auditor.address);
    });

    it("마감 전에는 BudgetNotExpired, 없는 예산은 BudgetNotFound", async function () {
      const f = await loadFixture(unitFixture);
      await expect((await reclaimBudget(f, { budgetId: 1n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetNotExpired")
        .withArgs(1n, f.expiresAt);
      await expect((await reclaimBudget(f, { budgetId: 9n, amount: 1n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetNotFound")
        .withArgs(9n);
    });

    it("회수하면 issued 가 spent 까지 내려가고 BudgetReclaimed(amount = 잔량). 잔량 0 이면 ZeroAmount", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 30_000n);
      await time.increaseTo(f.expiresAt + 1n);
      await expect(gas("BudgetToken.reclaim", (await reclaimBudget(f, { budgetId: 1n })).tx))
        .to.emit(f.budgetToken, "BudgetReclaimed")
        .withArgs(1n, 70_000n, f.president.address);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.issued).to.equal(30_000n);
      expect(b.spent).to.equal(30_000n);
      await assertInvariant(f, 1n);
      await expect((await reclaimBudget(f, { budgetId: 1n, amount: 0n })).tx).to.be.revertedWithCustomError(
        f.budgetToken,
        "ZeroAmount",
      );
    });

    it("같은 금액 환불 뒤 옛 회수 서명을 다시 제출하면 ReclaimCountMismatch (2차 리뷰 N3)", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 60_000n);
      await time.increaseTo(f.expiresAt + 1n);
      const first = await reclaimBudget(f, { budgetId: 1n }); // 40k 회수, reclaimCount 0
      await first.tx;
      await refund(f, 40_000n); // 잔량이 다시 40k — 금액 조건만으로는 옛 서명이 통과했다
      expect(await f.budgetToken.remaining(1n)).to.equal(40_000n);
      await expect(f.budgetToken.connect(f.outsider).reclaim(first.req, first.sig))
        .to.be.revertedWithCustomError(f.budgetToken, "ReclaimCountMismatch")
        .withArgs(1n, 1n, 0n);
      // 회장이 새로 서명하면 된다
      await expect((await reclaimBudget(f, { budgetId: 1n })).tx)
        .to.emit(f.budgetToken, "BudgetReclaimed")
        .withArgs(1n, 40_000n, f.president.address);
    });

    it("회수는 개정 번호(version)를 바꾸지 않고 reclaimCount 만 올린다", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 10_000n);
      await time.increaseTo(f.expiresAt + 1n);
      await (await reclaimBudget(f, { budgetId: 1n })).tx;
      await refund(f, 5_000n);
      await (await reclaimBudget(f, { budgetId: 1n })).tx;
      const b = await f.budgetToken.getBudget(1n);
      expect(b.version).to.equal(1n);
      expect(b.reclaimCount).to.equal(2n);
    });

    it("회수 금액이 현재 잔량과 다르면 ReclaimAmountMismatch", async function () {
      const f = await loadFixture(unitFixture);
      await spend(f, 30_000n);
      await time.increaseTo(f.expiresAt + 1n);
      await expect((await reclaimBudget(f, { budgetId: 1n, amount: 100_000n })).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "ReclaimAmountMismatch")
        .withArgs(1n, 70_000n, 100_000n);
    });

    it("이벤트 재계산식 Issued + Increased − Reclaimed − Spent + Refunded == remaining", async function () {
      const f = await loadFixture(unitFixture);
      await (await increaseBudget(f, { budgetId: 1n, amount: 20_000n })).tx;
      await spend(f, 50_000n);
      await refund(f, 10_000n);
      await time.increaseTo(f.expiresAt + 1n);
      await (await reclaimBudget(f, { budgetId: 1n })).tx;
      await refund(f, 5_000n, 13n);
      await (await reclaimBudget(f, { budgetId: 1n })).tx;

      const sum = async (name: string) => {
        const logs = await f.budgetToken.queryFilter(f.budgetToken.filters[name](1n));
        return logs.reduce((s: bigint, l: any) => s + BigInt(l.args.amount), 0n);
      };
      const recomputed =
        (await sum("BudgetIssued")) +
        (await sum("BudgetIncreased")) -
        (await sum("BudgetReclaimed")) -
        (await sum("BudgetSpent")) +
        (await sum("BudgetRefunded"));
      expect(recomputed).to.equal(await f.budgetToken.remaining(1n));
      expect(recomputed).to.equal(0n);
    });
  });

  describe("DOMAIN_SEPARATOR", function () {
    it("BudgetToken 도메인(BudgetToken, 1, chainId, 주소)과 일치한다", async function () {
      const f = await loadFixture(deployFixture);
      const { chainId } = await ethers.provider.getNetwork();
      expect(await f.budgetToken.DOMAIN_SEPARATOR()).to.equal(
        ethers.TypedDataEncoder.hashDomain({ name: "BudgetToken", version: "1", chainId, verifyingContract: f.addresses.BudgetToken }),
      );
      expect(await f.budgetToken.MAX_AMOUNT()).to.equal(MAX_AMOUNT);
    });
  });
});
