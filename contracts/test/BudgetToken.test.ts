import { expect } from "chai";
import {
  ethers,
  time,
  loadFixture,
  deployFixture,
  CATEGORY,
  TERM,
  ZERO32,
  ZERO_ADDR,
  textHash,
} from "./helpers/fixture.ts";
import { gas } from "./helpers/gas.ts";

const DAY = 24n * 3600n;

/**
 * BudgetToken 단독 픽스처. spend / refund 를 직접 부를 수 있게 원장 자리에 EOA(ledgerEoa)를 넣는다.
 * 원장을 거치는 경로는 AccountingLedger 테스트에서 본다.
 */
async function unitFixture() {
  const [deployer, president, treasurer, auditor, ledgerEoa, outsider] = await ethers.getSigners();
  const roleManager = await ethers.deployContract(
    "RoleManager",
    [president.address, treasurer.address, auditor.address],
    deployer,
  );
  const budgetToken = await ethers.deployContract("BudgetToken", [await roleManager.getAddress()], deployer);
  await budgetToken.connect(deployer).setLedger(ledgerEoa.address);

  const now = BigInt(await time.latest());
  const expiresAt = now + 30n * DAY;
  await budgetToken.connect(president).issue(1n, TERM, CATEGORY.행사비, 100_000n, expiresAt);

  return { deployer, president, treasurer, auditor, ledgerEoa, outsider, roleManager, budgetToken, expiresAt };
}

type Unit = Awaited<ReturnType<typeof unitFixture>>;

async function assertInvariant(f: Unit, budgetId: bigint) {
  const b = await f.budgetToken.getBudget(budgetId);
  expect(b.spent <= b.issued, `spent(${b.spent}) <= issued(${b.issued})`).to.equal(true);
  expect(await f.budgetToken.remaining(budgetId)).to.equal(b.issued - b.spent);
}

describe("BudgetToken", function () {
  describe("setLedger (배포자 1회)", function () {
    it("배포 직후 원장 주소가 설정되어 있고 LedgerSet 이 한 번 났다", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.budgetToken.ledger()).to.equal(f.addresses.AccountingLedger);
      const logs = await f.budgetToken.queryFilter(f.budgetToken.filters.LedgerSet());
      expect(logs.length).to.equal(1);
      expect(logs[0].args.ledger).to.equal(f.addresses.AccountingLedger);
    });

    it("두 번째 호출은 LedgerAlreadySet (배포자여도)", async function () {
      const f = await loadFixture(deployFixture);
      await expect(f.budgetToken.connect(f.deployer).setLedger(f.outsider.address))
        .to.be.revertedWithCustomError(f.budgetToken, "LedgerAlreadySet")
        .withArgs(f.addresses.AccountingLedger);
      expect(await f.budgetToken.ledger()).to.equal(f.addresses.AccountingLedger);
    });

    it("배포자가 아닌 계정의 첫 호출은 Unauthorized, 0 주소는 ZeroAddress", async function () {
      const [deployer, p, t, a, outsider] = await ethers.getSigners();
      const rm = await ethers.deployContract("RoleManager", [p.address, t.address, a.address], deployer);
      const bt = await ethers.deployContract("BudgetToken", [await rm.getAddress()], deployer);
      expect(await bt.ledger()).to.equal(ZERO_ADDR);

      await expect(bt.connect(outsider).setLedger(outsider.address))
        .to.be.revertedWithCustomError(bt, "Unauthorized")
        .withArgs(outsider.address);
      await expect(bt.connect(p).setLedger(outsider.address))
        .to.be.revertedWithCustomError(bt, "Unauthorized")
        .withArgs(p.address);
      await expect(bt.connect(deployer).setLedger(ZERO_ADDR)).to.be.revertedWithCustomError(bt, "ZeroAddress");

      await expect(bt.connect(deployer).setLedger(outsider.address))
        .to.emit(bt, "LedgerSet")
        .withArgs(outsider.address);
    });
  });

  describe("issue", function () {
    it("PRESIDENT 만 발행할 수 있다", async function () {
      const f = await loadFixture(unitFixture);
      for (const who of [f.treasurer, f.auditor, f.deployer, f.outsider, f.ledgerEoa]) {
        await expect(f.budgetToken.connect(who).issue(2n, TERM, CATEGORY.사업비, 1n, f.expiresAt))
          .to.be.revertedWithCustomError(f.budgetToken, "Unauthorized")
          .withArgs(who.address);
      }
    });

    it("발행하면 version 1, issued = amount, spent 0, BudgetIssued", async function () {
      const f = await loadFixture(unitFixture);
      await expect(
        gas("BudgetToken.issue", f.budgetToken.connect(f.president).issue(2n, TERM, CATEGORY.사업비, 50_000n, f.expiresAt)),
      )
        .to.emit(f.budgetToken, "BudgetIssued")
        .withArgs(2n, TERM, CATEGORY.사업비, 50_000n, f.expiresAt);

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
    });

    it("term == 0 은 TermRequired", async function () {
      const f = await loadFixture(unitFixture);
      await expect(
        f.budgetToken.connect(f.president).issue(2n, 0n, CATEGORY.사업비, 1n, f.expiresAt),
      ).to.be.revertedWithCustomError(f.budgetToken, "TermRequired");
    });

    it("amount == 0 은 ZeroAmount", async function () {
      const f = await loadFixture(unitFixture);
      await expect(
        f.budgetToken.connect(f.president).issue(2n, TERM, CATEGORY.사업비, 0n, f.expiresAt),
      ).to.be.revertedWithCustomError(f.budgetToken, "ZeroAmount");
    });

    it("같은 budgetId 는 BudgetAlreadyExists. id 0 은 예약이라 같은 에러", async function () {
      const f = await loadFixture(unitFixture);
      await expect(f.budgetToken.connect(f.president).issue(1n, TERM, CATEGORY.사업비, 1n, f.expiresAt))
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetAlreadyExists")
        .withArgs(1n);
      await expect(f.budgetToken.connect(f.president).issue(0n, TERM, CATEGORY.사업비, 1n, f.expiresAt))
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetAlreadyExists")
        .withArgs(0n);
      expect(await f.budgetToken.exists(0n)).to.equal(false);
    });

    it("이미 지난 마감으로는 발행할 수 없다 (BudgetExpired)", async function () {
      const f = await loadFixture(unitFixture);
      const past = BigInt(await time.latest()) - 1n;
      await expect(f.budgetToken.connect(f.president).issue(2n, TERM, CATEGORY.사업비, 1n, past))
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetExpired")
        .withArgs(2n, past);
    });
  });

  describe("increase (증액만)", function () {
    it("PRESIDENT 만 증액할 수 있다", async function () {
      const f = await loadFixture(unitFixture);
      await expect(f.budgetToken.connect(f.treasurer).increase(1n, 1n, ZERO32))
        .to.be.revertedWithCustomError(f.budgetToken, "Unauthorized")
        .withArgs(f.treasurer.address);
    });

    it("없는 예산은 BudgetNotFound, 0 원 증액은 ZeroAmount", async function () {
      const f = await loadFixture(unitFixture);
      await expect(f.budgetToken.connect(f.president).increase(9n, 1n, ZERO32))
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetNotFound")
        .withArgs(9n);
      await expect(f.budgetToken.connect(f.president).increase(1n, 0n, ZERO32)).to.be.revertedWithCustomError(
        f.budgetToken,
        "ZeroAmount",
      );
    });

    it("증액하면 issued 가 더해지고 version 이 오르며 BudgetIncreased 에 사유 해시가 남는다", async function () {
      const f = await loadFixture(unitFixture);
      const reason = textHash("행사 규모 확대");
      await expect(gas("BudgetToken.increase", f.budgetToken.connect(f.president).increase(1n, 20_000n, reason)))
        .to.emit(f.budgetToken, "BudgetIncreased")
        .withArgs(1n, 20_000n, 2n, reason);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.issued).to.equal(120_000n);
      expect(b.version).to.equal(2n);

      await f.budgetToken.connect(f.president).increase(1n, 5_000n, reason);
      expect((await f.budgetToken.getBudget(1n)).version).to.equal(3n);
      expect((await f.budgetToken.getBudget(1n)).issued).to.equal(125_000n);
    });

    it("감액 함수는 ABI 에 없다", async function () {
      const f = await loadFixture(unitFixture);
      const names = f.budgetToken.interface.fragments
        .filter((x: any) => x.type === "function")
        .map((x: any) => x.name);
      expect(names).to.not.include.members(["decrease", "reduce", "setIssued", "setAllocated"]);
    });
  });

  describe("spend — 필수 테스트 8: 원장 외 호출자는 revert", function () {
    it("원장이 아닌 계정의 spend 는 Unauthorized (회장·배포자·외부인 모두)", async function () {
      const f = await loadFixture(unitFixture);
      for (const who of [f.president, f.deployer, f.outsider, f.treasurer]) {
        await expect(f.budgetToken.connect(who).spend(1n, 1n, 1n))
          .to.be.revertedWithCustomError(f.budgetToken, "Unauthorized")
          .withArgs(who.address);
      }
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(0n);
    });

    it("실제 배포에서도 원장 컨트랙트 외에는 spend·refund 를 부를 수 없다", async function () {
      const f = await loadFixture(deployFixture);
      await expect(f.budgetToken.connect(f.president).spend(1n, 1n, 1n))
        .to.be.revertedWithCustomError(f.budgetToken, "Unauthorized")
        .withArgs(f.president.address);
      await expect(f.budgetToken.connect(f.deployer).refund(1n, 1n, 1n))
        .to.be.revertedWithCustomError(f.budgetToken, "Unauthorized")
        .withArgs(f.deployer.address);
    });

    it("원장이 부르면 spent 가 오르고 BudgetSpent 가 난다", async function () {
      const f = await loadFixture(unitFixture);
      await expect(gas("BudgetToken.spend", f.budgetToken.connect(f.ledgerEoa).spend(1n, 30_000n, 11n)))
        .to.emit(f.budgetToken, "BudgetSpent")
        .withArgs(1n, 30_000n, 11n);
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(30_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(70_000n);
      await assertInvariant(f, 1n);
    });

    it("잔량을 넘으면 InsufficientBudget(budgetId, remaining, requested)", async function () {
      const f = await loadFixture(unitFixture);
      await f.budgetToken.connect(f.ledgerEoa).spend(1n, 30_000n, 11n);
      await expect(f.budgetToken.connect(f.ledgerEoa).spend(1n, 70_001n, 12n))
        .to.be.revertedWithCustomError(f.budgetToken, "InsufficientBudget")
        .withArgs(1n, 70_000n, 70_001n);
      await expect(f.budgetToken.connect(f.ledgerEoa).spend(1n, 70_000n, 12n)).to.not.be.revert(ethers);
      expect(await f.budgetToken.remaining(1n)).to.equal(0n);
    });

    it("없는 예산·0 원은 revert", async function () {
      const f = await loadFixture(unitFixture);
      await expect(f.budgetToken.connect(f.ledgerEoa).spend(9n, 1n, 1n))
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetNotFound")
        .withArgs(9n);
      await expect(f.budgetToken.connect(f.ledgerEoa).spend(1n, 0n, 1n)).to.be.revertedWithCustomError(
        f.budgetToken,
        "ZeroAmount",
      );
    });

    it("마감이 지나면 BudgetExpired", async function () {
      const f = await loadFixture(unitFixture);
      await time.increaseTo(f.expiresAt + 1n);
      await expect(f.budgetToken.connect(f.ledgerEoa).spend(1n, 1n, 1n))
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetExpired")
        .withArgs(1n, f.expiresAt);
    });
  });

  describe("refund — 마감·회수와 무관하게 소모액 범위 안에서 항상 성공", function () {
    it("원장이 아닌 계정의 refund 는 Unauthorized", async function () {
      const f = await loadFixture(unitFixture);
      await f.budgetToken.connect(f.ledgerEoa).spend(1n, 30_000n, 11n);
      await expect(f.budgetToken.connect(f.president).refund(1n, 1n, 12n))
        .to.be.revertedWithCustomError(f.budgetToken, "Unauthorized")
        .withArgs(f.president.address);
    });

    it("refund 는 spent 만 줄이고 BudgetRefunded 를 낸다", async function () {
      const f = await loadFixture(unitFixture);
      await f.budgetToken.connect(f.ledgerEoa).spend(1n, 30_000n, 11n);
      await expect(gas("BudgetToken.refund", f.budgetToken.connect(f.ledgerEoa).refund(1n, 10_000n, 12n)))
        .to.emit(f.budgetToken, "BudgetRefunded")
        .withArgs(1n, 10_000n, 12n);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.spent).to.equal(20_000n);
      expect(b.issued).to.equal(100_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(80_000n);
      await assertInvariant(f, 1n);
    });

    it("소모액을 넘는 refund 는 RefundExceedsSpent(budgetId, spent, requested)", async function () {
      const f = await loadFixture(unitFixture);
      await f.budgetToken.connect(f.ledgerEoa).spend(1n, 30_000n, 11n);
      await expect(f.budgetToken.connect(f.ledgerEoa).refund(1n, 30_001n, 12n))
        .to.be.revertedWithCustomError(f.budgetToken, "RefundExceedsSpent")
        .withArgs(1n, 30_000n, 30_001n);
      await expect(f.budgetToken.connect(f.ledgerEoa).refund(1n, 0n, 12n)).to.be.revertedWithCustomError(
        f.budgetToken,
        "ZeroAmount",
      );
    });

    it("마감 뒤에도 refund 는 성공한다", async function () {
      const f = await loadFixture(unitFixture);
      await f.budgetToken.connect(f.ledgerEoa).spend(1n, 30_000n, 11n);
      await time.increaseTo(f.expiresAt + 1n);
      await expect(f.budgetToken.connect(f.ledgerEoa).refund(1n, 30_000n, 12n)).to.not.be.revert(ethers);
      expect((await f.budgetToken.getBudget(1n)).spent).to.equal(0n);
      await assertInvariant(f, 1n);
    });

    it("회수 뒤에도 refund 는 성공하고 remaining 이 다시 생기지만 spend 는 막힌다 (회수 → refund → spend revert)", async function () {
      const f = await loadFixture(unitFixture);
      await f.budgetToken.connect(f.ledgerEoa).spend(1n, 60_000n, 11n);
      await time.increaseTo(f.expiresAt + 1n);
      await f.budgetToken.connect(f.president).reclaim(1n); // issued 100k → 60k
      expect(await f.budgetToken.remaining(1n)).to.equal(0n);

      await expect(f.budgetToken.connect(f.ledgerEoa).refund(1n, 20_000n, 12n)).to.not.be.revert(ethers);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.issued).to.equal(60_000n);
      expect(b.spent).to.equal(40_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(20_000n);
      await assertInvariant(f, 1n);

      await expect(f.budgetToken.connect(f.ledgerEoa).spend(1n, 10_000n, 13n))
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetExpired")
        .withArgs(1n, f.expiresAt);

      // 다시 회수하면 된다
      await expect(f.budgetToken.connect(f.president).reclaim(1n))
        .to.emit(f.budgetToken, "BudgetReclaimed")
        .withArgs(1n, 20_000n, f.president.address);
      expect((await f.budgetToken.getBudget(1n)).issued).to.equal(40_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(0n);
    });

    it("증액 후 refund → remaining 이 issued 를 넘지 않는다", async function () {
      const f = await loadFixture(unitFixture);
      await f.budgetToken.connect(f.ledgerEoa).spend(1n, 80_000n, 11n);
      await f.budgetToken.connect(f.president).increase(1n, 50_000n, ZERO32); // issued 150k
      await f.budgetToken.connect(f.ledgerEoa).refund(1n, 80_000n, 12n);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.issued).to.equal(150_000n);
      expect(b.spent).to.equal(0n);
      expect(await f.budgetToken.remaining(1n)).to.equal(150_000n);
      await assertInvariant(f, 1n);
      await expect(f.budgetToken.connect(f.ledgerEoa).refund(1n, 1n, 13n)).to.be.revertedWithCustomError(
        f.budgetToken,
        "RefundExceedsSpent",
      );
    });
  });

  describe("reclaim (마감 뒤에만, 재호출 가능)", function () {
    it("PRESIDENT 만 회수할 수 있다", async function () {
      const f = await loadFixture(unitFixture);
      await time.increaseTo(f.expiresAt + 1n);
      await expect(f.budgetToken.connect(f.auditor).reclaim(1n))
        .to.be.revertedWithCustomError(f.budgetToken, "Unauthorized")
        .withArgs(f.auditor.address);
    });

    it("마감 전에는 BudgetNotExpired", async function () {
      const f = await loadFixture(unitFixture);
      await expect(f.budgetToken.connect(f.president).reclaim(1n))
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetNotExpired")
        .withArgs(1n, f.expiresAt);
    });

    it("없는 예산은 BudgetNotFound", async function () {
      const f = await loadFixture(unitFixture);
      await expect(f.budgetToken.connect(f.president).reclaim(9n))
        .to.be.revertedWithCustomError(f.budgetToken, "BudgetNotFound")
        .withArgs(9n);
    });

    it("회수하면 issued 가 spent 까지 내려가고 BudgetReclaimed(amount = 회수된 잔량). 잔량 0 이면 ZeroAmount", async function () {
      const f = await loadFixture(unitFixture);
      await f.budgetToken.connect(f.ledgerEoa).spend(1n, 30_000n, 11n);
      await time.increaseTo(f.expiresAt + 1n);
      await expect(gas("BudgetToken.reclaim", f.budgetToken.connect(f.president).reclaim(1n)))
        .to.emit(f.budgetToken, "BudgetReclaimed")
        .withArgs(1n, 70_000n, f.president.address);
      const b = await f.budgetToken.getBudget(1n);
      expect(b.issued).to.equal(30_000n);
      expect(b.spent).to.equal(30_000n);
      expect(await f.budgetToken.remaining(1n)).to.equal(0n);
      await assertInvariant(f, 1n);

      await expect(f.budgetToken.connect(f.president).reclaim(1n)).to.be.revertedWithCustomError(
        f.budgetToken,
        "ZeroAmount",
      );
    });

    it("이벤트 재계산식 Issued + Increased − Reclaimed − Spent + Refunded == remaining", async function () {
      const f = await loadFixture(unitFixture);
      await f.budgetToken.connect(f.president).increase(1n, 20_000n, ZERO32);
      await f.budgetToken.connect(f.ledgerEoa).spend(1n, 50_000n, 11n);
      await f.budgetToken.connect(f.ledgerEoa).refund(1n, 10_000n, 12n);
      await time.increaseTo(f.expiresAt + 1n);
      await f.budgetToken.connect(f.president).reclaim(1n);
      await f.budgetToken.connect(f.ledgerEoa).refund(1n, 5_000n, 13n);
      await f.budgetToken.connect(f.president).reclaim(1n);

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
});
