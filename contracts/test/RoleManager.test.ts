import { expect } from "chai";
import {
  ethers,
  time,
  loadFixture,
  deployFixture,
  type Fixture,
  ROLE,
  ZERO_ADDR,
  CATEGORY,
  RECOVERY_DELAY,
  changeRole,
  makeRoleChange,
  signRoleChange,
  proposeRecovery,
  cancelRecovery,
  issueBudget,
} from "./helpers/fixture.ts";
import { gas } from "./helpers/gas.ts";

/** 감사 2명이 회장 복구를 제안하고 72시간을 기다린다. */
async function proposeAndWait(f: Fixture, to: string) {
  const p = await proposeRecovery(f, { from: f.president.address, to });
  await p.tx;
  await time.increase(RECOVERY_DELAY);
  return p;
}

describe("RoleManager", function () {
  describe("배포 (생성자)", function () {
    it("회장·총무·감사 2명이 롤을 갖고, 배포자·릴레이어는 어떤 롤도 없다", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.president.address)).to.equal(true);
      expect(await f.roleManager.hasRole(ROLE.TREASURER, f.treasurer.address)).to.equal(true);
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.auditor.address)).to.equal(true);
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.auditor2.address)).to.equal(true);
      expect(await f.roleManager.holderCount(ROLE.PRESIDENT)).to.equal(1n);
      expect(await f.roleManager.holderCount(ROLE.TREASURER)).to.equal(1n);
      expect(await f.roleManager.holderCount(ROLE.AUDITOR)).to.equal(2n);
      expect(await f.roleManager.MIN_AUDITORS()).to.equal(2n);
      expect(await f.roleManager.RECOVERY_DELAY()).to.equal(RECOVERY_DELAY);
      expect(await f.roleManager.nonce()).to.equal(0n);

      for (const who of [f.deployer, f.relayer, f.outsider]) {
        expect(await f.roleManager.roleOf(who.address)).to.equal(ethers.ZeroHash);
        expect(await f.roleManager.isGovernor(who.address)).to.equal(false);
      }
      expect(await f.roleManager.isGovernor(f.treasurer.address)).to.equal(false);
      expect(await f.roleManager.isGovernor(f.president.address)).to.equal(true);
      expect(await f.roleManager.isGovernor(f.auditor2.address)).to.equal(true);
    });

    it("생성자 부여 이벤트 4건은 proposer·approver 가 0 이다 (최초 부여 표시)", async function () {
      const f = await loadFixture(deployFixture);
      const logs = await f.roleManager.queryFilter(f.roleManager.filters.RoleGranted());
      expect(logs.length).to.equal(4);
      for (const l of logs) {
        expect(l.args.proposer).to.equal(ZERO_ADDR);
        expect(l.args.approver).to.equal(ZERO_ADDR);
      }
    });

    it("롤 식별자는 이름의 keccak256, DOMAIN_SEPARATOR 는 RoleManager 도메인", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.roleManager.TREASURER()).to.equal(ROLE.TREASURER);
      expect(await f.roleManager.AUDITOR()).to.equal(ROLE.AUDITOR);
      expect(await f.roleManager.PRESIDENT()).to.equal(ROLE.PRESIDENT);
      const { chainId } = await ethers.provider.getNetwork();
      expect(await f.roleManager.DOMAIN_SEPARATOR()).to.equal(
        ethers.TypedDataEncoder.hashDomain({ name: "RoleManager", version: "1", chainId, verifyingContract: f.addresses.RoleManager }),
      );
    });

    it("생성자 인자에 0 주소가 있으면 ZeroAddress, 중복이면 AlreadyOfficer", async function () {
      const [, p, t, a, , a2] = await ethers.getSigners();
      const factory = await ethers.getContractFactory("RoleManager");
      await expect(factory.deploy(p.address, t.address, a.address, ZERO_ADDR)).to.be.revertedWithCustomError(factory, "ZeroAddress");
      await expect(factory.deploy(p.address, t.address, a.address, a.address))
        .to.be.revertedWithCustomError(factory, "AlreadyOfficer")
        .withArgs(a.address, ROLE.AUDITOR);
      await expect(factory.deploy(p.address, t.address, t.address, a2.address))
        .to.be.revertedWithCustomError(factory, "AlreadyOfficer")
        .withArgs(t.address, ROLE.TREASURER);
    });
  });

  describe("필수 테스트 9: 회장과 감사의 서명 없이는 일반 변경이 실행되지 않는다", function () {
    it("감사 둘만의 서명은 PresidentRequired — 회장 교체·총무 교체·감사 추가 모두 (2차 리뷰 N2)", async function () {
      const f = await loadFixture(deployFixture);
      const cases = [
        { role: ROLE.PRESIDENT, from: f.president.address, to: f.extra1.address },
        { role: ROLE.TREASURER, from: f.treasurer.address, to: f.extra1.address },
        { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address },
      ];
      for (const o of cases) {
        await expect((await changeRole(f, o, f.auditor, f.auditor2)).tx).to.be.revertedWithCustomError(
          f.roleManager,
          "PresidentRequired",
        );
      }
      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.president.address)).to.equal(true);
    });

    it("같은 사람이 두 서명을 하면 SameSigner", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address }, f.president, f.president)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "SameSigner")
        .withArgs(f.president.address);
    });

    it("총무·외부인·릴레이어·배포자 서명은 NotGovernor (제안자·승인자 어느 자리든)", async function () {
      const f = await loadFixture(deployFixture);
      const o = { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address };
      for (const who of [f.treasurer, f.outsider, f.relayer, f.deployer]) {
        await expect((await changeRole(f, o, who, f.president)).tx)
          .to.be.revertedWithCustomError(f.roleManager, "NotGovernor")
          .withArgs(who.address);
        await expect((await changeRole(f, o, f.president, who)).tx)
          .to.be.revertedWithCustomError(f.roleManager, "NotGovernor")
          .withArgs(who.address);
      }
      expect(await f.roleManager.nonce()).to.equal(0n);
    });

    it("총무가 자기 두 번째 키를 감사로 올릴 수 없다 (총무 + 회장도 불가)", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address }, f.treasurer, f.president)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "NotGovernor")
        .withArgs(f.treasurer.address);
    });

    it("회장·감사 서명 순서는 상관없다", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address }, f.auditor2, f.president)).tx)
        .to.emit(f.roleManager, "RoleGranted")
        .withArgs(ROLE.AUDITOR, f.extra1.address, f.auditor2.address, f.president.address);
    });

    it("깨진 서명은 InvalidSignature", async function () {
      const f = await loadFixture(deployFixture);
      const change = await makeRoleChange(f.roleManager, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address });
      const good = await signRoleChange(f.president, f.roleManager, change);
      await expect(f.roleManager.connect(f.relayer).changeRole(change, good, "0x1234")).to.be.revertedWithCustomError(
        f.roleManager,
        "InvalidSignature",
      );
    });
  });

  describe("서명 수명 (deadline · nonce)", function () {
    it("deadline 이 지난 서명은 SignatureExpired", async function () {
      const f = await loadFixture(deployFixture);
      const past = BigInt(await time.latest()) - 1n;
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address, deadline: past }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "SignatureExpired")
        .withArgs(past);
    });

    it("같은 서명 재제출, 먼저 받아 둔 다른 변경의 서명은 InvalidNonce", async function () {
      const f = await loadFixture(deployFixture);
      const a = await makeRoleChange(f.roleManager, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address });
      const b = await makeRoleChange(f.roleManager, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra2.address });
      const aP = await signRoleChange(f.president, f.roleManager, a);
      const aA = await signRoleChange(f.auditor, f.roleManager, a);
      const bP = await signRoleChange(f.president, f.roleManager, b);
      const bA = await signRoleChange(f.auditor, f.roleManager, b);

      await f.roleManager.connect(f.relayer).changeRole(a, aP, aA);
      expect(await f.roleManager.nonce()).to.equal(1n);
      await expect(f.roleManager.connect(f.relayer).changeRole(a, aP, aA))
        .to.be.revertedWithCustomError(f.roleManager, "InvalidNonce")
        .withArgs(1n, 0n);
      await expect(f.roleManager.connect(f.relayer).changeRole(b, bP, bA))
        .to.be.revertedWithCustomError(f.roleManager, "InvalidNonce")
        .withArgs(1n, 0n);
    });

    it("세 롤 외의 role 은 UnknownRole, from·to 둘 다 0 이면 ZeroAddress", async function () {
      const f = await loadFixture(deployFixture);
      const bogus = ethers.keccak256(ethers.toUtf8Bytes("STUDENT"));
      await expect((await changeRole(f, { role: bogus, from: ZERO_ADDR, to: f.extra1.address }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "UnknownRole")
        .withArgs(bogus);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: ZERO_ADDR }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "ZeroAddress");
    });
  });

  describe("부여 (from == 0)", function () {
    it("감사를 더 둘 수 있다. RoleGranted·RoleChangeExecuted 에 제안자·승인자가 남는다", async function () {
      const f = await loadFixture(deployFixture);
      const { tx } = await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address }, f.president, f.auditor);
      await expect(gas("RoleManager.changeRole (grant)", tx))
        .to.emit(f.roleManager, "RoleGranted")
        .withArgs(ROLE.AUDITOR, f.extra1.address, f.president.address, f.auditor.address)
        .and.to.emit(f.roleManager, "RoleChangeExecuted")
        .withArgs(0n, ROLE.AUDITOR, ZERO_ADDR, f.extra1.address, f.president.address, f.auditor.address)
        .and.not.to.emit(f.roleManager, "RoleRevoked");
      expect(await f.roleManager.holderCount(ROLE.AUDITOR)).to.equal(3n);
      expect(await f.roleManager.nonce()).to.equal(1n);
    });

    it("보유자가 있는 회장·총무에 부여하면 RoleCapacityExceeded", async function () {
      const f = await loadFixture(deployFixture);
      for (const role of [ROLE.PRESIDENT, ROLE.TREASURER]) {
        await expect((await changeRole(f, { role, from: ZERO_ADDR, to: f.extra1.address }, f.president, f.auditor)).tx)
          .to.be.revertedWithCustomError(f.roleManager, "RoleCapacityExceeded")
          .withArgs(role);
      }
    });

    it("이미 같은 롤이면 RoleAlreadyGranted, 다른 임원 롤이면 AlreadyOfficer", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.auditor2.address }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "RoleAlreadyGranted")
        .withArgs(ROLE.AUDITOR, f.auditor2.address);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.treasurer.address }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "AlreadyOfficer")
        .withArgs(f.treasurer.address, ROLE.TREASURER);
    });
  });

  describe("회수 (to == 0)", function () {
    it("감사 3명에서 1명 회수는 성공, 2명에서는 RoleMinimumViolated", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: f.auditor2.address, to: ZERO_ADDR }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "RoleMinimumViolated")
        .withArgs(ROLE.AUDITOR);

      await (await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address }, f.president, f.auditor)).tx;
      const { tx } = await changeRole(f, { role: ROLE.AUDITOR, from: f.auditor2.address, to: ZERO_ADDR }, f.president, f.auditor);
      await expect(gas("RoleManager.changeRole (revoke)", tx))
        .to.emit(f.roleManager, "RoleRevoked")
        .withArgs(ROLE.AUDITOR, f.auditor2.address, f.president.address, f.auditor.address);
      expect(await f.roleManager.holderCount(ROLE.AUDITOR)).to.equal(2n);
    });

    it("회장·총무는 회수할 수 없다 (RoleMinimumViolated)", async function () {
      const f = await loadFixture(deployFixture);
      for (const [role, holder] of [
        [ROLE.PRESIDENT, f.president.address],
        [ROLE.TREASURER, f.treasurer.address],
      ] as const) {
        await expect((await changeRole(f, { role, from: holder, to: ZERO_ADDR }, f.president, f.auditor)).tx)
          .to.be.revertedWithCustomError(f.roleManager, "RoleMinimumViolated")
          .withArgs(role);
      }
    });

    it("롤을 갖고 있지 않은 from 을 회수하면 RoleNotGranted", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: f.treasurer.address, to: ZERO_ADDR }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "RoleNotGranted")
        .withArgs(ROLE.AUDITOR, f.treasurer.address);
    });
  });

  describe("교체 (from != 0 && to != 0)", function () {
    it("총무 교체: RoleRevoked + RoleGranted + RoleChangeExecuted, 보유자 수 불변", async function () {
      const f = await loadFixture(deployFixture);
      const { tx } = await changeRole(f, { role: ROLE.TREASURER, from: f.treasurer.address, to: f.extra2.address }, f.president, f.auditor);
      await expect(gas("RoleManager.changeRole (replace)", tx))
        .to.emit(f.roleManager, "RoleRevoked")
        .withArgs(ROLE.TREASURER, f.treasurer.address, f.president.address, f.auditor.address)
        .and.to.emit(f.roleManager, "RoleGranted")
        .withArgs(ROLE.TREASURER, f.extra2.address, f.president.address, f.auditor.address)
        .and.to.emit(f.roleManager, "RoleChangeExecuted")
        .withArgs(0n, ROLE.TREASURER, f.treasurer.address, f.extra2.address, f.president.address, f.auditor.address);
      expect(await f.roleManager.holderCount(ROLE.TREASURER)).to.equal(1n);
    });

    it("회장 자발적 교체: 나가는 회장 + 감사 서명", async function () {
      const f = await loadFixture(deployFixture);
      await (await changeRole(f, { role: ROLE.PRESIDENT, from: f.president.address, to: f.extra1.address }, f.president, f.auditor)).tx;
      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.extra1.address)).to.equal(true);
      expect(await f.roleManager.isGovernor(f.president.address)).to.equal(false);
    });

    it("from == to 는 RoleAlreadyGranted, to 가 다른 임원이면 AlreadyOfficer", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await changeRole(f, { role: ROLE.TREASURER, from: f.treasurer.address, to: f.treasurer.address }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "RoleAlreadyGranted")
        .withArgs(ROLE.TREASURER, f.treasurer.address);
      await expect((await changeRole(f, { role: ROLE.TREASURER, from: f.treasurer.address, to: f.auditor.address }, f.president, f.auditor2)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "AlreadyOfficer")
        .withArgs(f.auditor.address, ROLE.AUDITOR);
    });
  });

  describe("키 분실 — 잃어버린 키는 한 번도 서명하지 않는다 (2차 리뷰 N1)", function () {
    it("감사 한 명의 키 분실: 회장 + 다른 감사가 그 감사를 교체한다", async function () {
      const f = await loadFixture(deployFixture);
      // f.auditor 의 키를 잃었다고 가정. 이후 f.auditor 는 어떤 서명도 하지 않는다.
      await (await changeRole(f, { role: ROLE.AUDITOR, from: f.auditor.address, to: f.extra1.address }, f.president, f.auditor2)).tx;
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.auditor.address)).to.equal(false);
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.extra1.address)).to.equal(true);
      expect(await f.roleManager.holderCount(ROLE.AUDITOR)).to.equal(2n);
    });

    it("회장 키 분실: 감사 2명 제안 → 72시간 대기 → 실행. 새 회장이 예산을 발행할 수 있다", async function () {
      const f = await loadFixture(deployFixture);
      // f.president 의 키를 잃었다고 가정. 이후 f.president 는 어떤 서명도 하지 않는다.
      const p = await proposeRecovery(f, { from: f.president.address, to: f.extra1.address });
      const sent = await gas("RoleManager.proposePresidentRecovery", p.tx);
      const receipt = await sent.wait();
      const proposedAt = BigInt((await ethers.provider.getBlock(receipt.blockNumber))!.timestamp);
      const logs = await f.roleManager.queryFilter(f.roleManager.filters.PresidentRecoveryProposed(), receipt.blockNumber);
      expect(logs.length).to.equal(1);
      expect(logs[0].args.recoveryId).to.equal(0n);
      expect(logs[0].args.from).to.equal(f.president.address);
      expect(logs[0].args.to).to.equal(f.extra1.address);
      expect(logs[0].args.auditorA).to.equal(f.auditor.address);
      expect(logs[0].args.auditorB).to.equal(f.auditor2.address);
      expect(logs[0].args.executableAt).to.equal(proposedAt + RECOVERY_DELAY);
      const pending = await f.roleManager.pendingRecovery();
      expect(pending.executableAt).to.equal(proposedAt + RECOVERY_DELAY);
      expect(pending.recoveryId).to.equal(0n);
      expect(pending.to).to.equal(f.extra1.address);
      expect(await f.roleManager.nonce()).to.equal(1n);

      // 대기 전에는 실행 불가
      await expect(f.roleManager.connect(f.outsider).executePresidentRecovery())
        .to.be.revertedWithCustomError(f.roleManager, "RecoveryNotReady")
        .withArgs(pending.executableAt);

      await time.increaseTo(pending.executableAt);
      await expect(gas("RoleManager.executePresidentRecovery", f.roleManager.connect(f.outsider).executePresidentRecovery()))
        .to.emit(f.roleManager, "RoleRevoked")
        .withArgs(ROLE.PRESIDENT, f.president.address, f.auditor.address, f.auditor2.address)
        .and.to.emit(f.roleManager, "RoleGranted")
        .withArgs(ROLE.PRESIDENT, f.extra1.address, f.auditor.address, f.auditor2.address)
        .and.to.emit(f.roleManager, "RoleChangeExecuted")
        .withArgs(1n, ROLE.PRESIDENT, f.president.address, f.extra1.address, f.auditor.address, f.auditor2.address);

      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.extra1.address)).to.equal(true);
      expect(await f.roleManager.holderCount(ROLE.PRESIDENT)).to.equal(1n);
      expect(await f.roleManager.nonce()).to.equal(2n);
      expect((await f.roleManager.pendingRecovery()).executableAt).to.equal(0n);

      // 회장 서명이 필요한 예산 발행이 새 회장으로 다시 된다
      const expiresAt = BigInt(await time.latest()) + 30n * 24n * 3600n;
      await expect((await issueBudget(f, { budgetId: 1n, category: CATEGORY.행사비, amount: 1n, expiresAt }, f.extra1)).tx).to.emit(
        f.budgetToken,
        "BudgetIssued",
      );
      await expect((await issueBudget(f, { budgetId: 2n, category: CATEGORY.사업비, amount: 1n, expiresAt }, f.president)).tx)
        .to.be.revertedWithCustomError(f.budgetToken, "NotPresident")
        .withArgs(f.president.address);
    });
  });

  describe("회장 복구 — 담합 방지와 경계 조건", function () {
    it("살아 있는 회장은 대기 중에 취소한다. 이후 실행은 NoPendingRecovery", async function () {
      const f = await loadFixture(deployFixture);
      const p = await proposeRecovery(f, { from: f.president.address, to: f.extra1.address });
      await p.tx;
      await expect(gas("RoleManager.cancelPresidentRecovery", (await cancelRecovery(f, p.recoveryId)).tx))
        .to.emit(f.roleManager, "PresidentRecoveryCancelled")
        .withArgs(p.recoveryId, f.president.address);
      await time.increase(RECOVERY_DELAY);
      await expect(f.roleManager.executePresidentRecovery())
        .to.be.revertedWithCustomError(f.roleManager, "NoPendingRecovery")
        .withArgs(0n);
      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.president.address)).to.equal(true);
    });

    it("취소: 회장이 아니면 NotPresident, id 가 다르면 NoPendingRecovery", async function () {
      const f = await loadFixture(deployFixture);
      const p = await proposeRecovery(f, { from: f.president.address, to: f.extra1.address });
      await p.tx;
      for (const who of [f.auditor, f.treasurer, f.outsider]) {
        await expect((await cancelRecovery(f, p.recoveryId, who)).tx)
          .to.be.revertedWithCustomError(f.roleManager, "NotPresident")
          .withArgs(who.address);
      }
      await expect((await cancelRecovery(f, 99n)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "NoPendingRecovery")
        .withArgs(99n);
    });

    it("제안: 감사가 아니면 NotAuditor, 같은 감사 두 서명은 SameSigner, 서명 재사용은 InvalidNonce", async function () {
      const f = await loadFixture(deployFixture);
      const o = { from: f.president.address, to: f.extra1.address };
      await expect((await proposeRecovery(f, o, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "NotAuditor")
        .withArgs(f.president.address);
      await expect((await proposeRecovery(f, o, f.auditor, f.treasurer)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "NotAuditor")
        .withArgs(f.treasurer.address);
      await expect((await proposeRecovery(f, o, f.auditor, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "SameSigner")
        .withArgs(f.auditor.address);

      const p = await proposeRecovery(f, o);
      await p.tx;
      await expect(f.roleManager.connect(f.relayer).proposePresidentRecovery(p.recovery, p.sa, p.sb))
        .to.be.revertedWithCustomError(f.roleManager, "InvalidNonce")
        .withArgs(1n, 0n);
    });

    it("제안: from 이 회장이 아니면 RoleNotGranted, to 가 0 이면 ZeroAddress, to 가 임원이면 AlreadyOfficer", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await proposeRecovery(f, { from: f.treasurer.address, to: f.extra1.address })).tx)
        .to.be.revertedWithCustomError(f.roleManager, "RoleNotGranted")
        .withArgs(ROLE.PRESIDENT, f.treasurer.address);
      await expect((await proposeRecovery(f, { from: f.president.address, to: ZERO_ADDR })).tx).to.be.revertedWithCustomError(
        f.roleManager,
        "ZeroAddress",
      );
      await expect((await proposeRecovery(f, { from: f.president.address, to: f.auditor.address })).tx)
        .to.be.revertedWithCustomError(f.roleManager, "AlreadyOfficer")
        .withArgs(f.auditor.address, ROLE.AUDITOR);
    });

    it("대기 중 제안한 감사가 교체되면 실행은 NotAuditor", async function () {
      const f = await loadFixture(deployFixture);
      await proposeAndWait(f, f.extra1.address);
      // 회장 + 남은 감사가 auditor2 를 교체 (회장이 살아 있어 취소 대신 이렇게 대응했다고 가정)
      await (await changeRole(f, { role: ROLE.AUDITOR, from: f.auditor2.address, to: f.extra2.address }, f.president, f.auditor)).tx;
      await expect(f.roleManager.executePresidentRecovery())
        .to.be.revertedWithCustomError(f.roleManager, "NotAuditor")
        .withArgs(f.auditor2.address);
    });

    it("회장이 일반 교체로 바뀌면 대기 복구가 지워진다. 옛 회장이 돌아와도 되살아나지 않는다 (code-review)", async function () {
      const f = await loadFixture(deployFixture);
      const p = await proposeRecovery(f, { from: f.president.address, to: f.extra1.address });
      await p.tx;
      expect((await f.roleManager.pendingRecovery()).executableAt).to.not.equal(0n);

      // 회장이 취소 대신 일반 교체로 자리를 넘긴다
      await (await changeRole(f, { role: ROLE.PRESIDENT, from: f.president.address, to: f.extra2.address }, f.president, f.auditor)).tx;
      expect((await f.roleManager.pendingRecovery()).executableAt).to.equal(0n);

      // 옛 회장이 다시 회장이 되고 72시간이 지나도 옛 제안은 실행되지 않는다
      await (await changeRole(f, { role: ROLE.PRESIDENT, from: f.extra2.address, to: f.president.address }, f.extra2, f.auditor)).tx;
      await time.increase(RECOVERY_DELAY);
      await expect(f.roleManager.executePresidentRecovery())
        .to.be.revertedWithCustomError(f.roleManager, "NoPendingRecovery")
        .withArgs(0n);
      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.president.address)).to.equal(true);
      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.extra1.address)).to.equal(false);
    });

    it("복구 실행 뒤에도 대기 복구는 남지 않는다 (새 회장을 겨냥한 옛 제안 없음)", async function () {
      const f = await loadFixture(deployFixture);
      await proposeAndWait(f, f.extra1.address);
      await f.roleManager.executePresidentRecovery();
      expect((await f.roleManager.pendingRecovery()).executableAt).to.equal(0n);
      await expect(f.roleManager.executePresidentRecovery()).to.be.revertedWithCustomError(f.roleManager, "NoPendingRecovery");
    });

    it("대기 중 to 가 임원이 되면 실행은 AlreadyOfficer", async function () {
      const f = await loadFixture(deployFixture);
      await proposeAndWait(f, f.extra1.address);
      await (await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address }, f.president, f.auditor)).tx;
      await expect(f.roleManager.executePresidentRecovery())
        .to.be.revertedWithCustomError(f.roleManager, "AlreadyOfficer")
        .withArgs(f.extra1.address, ROLE.AUDITOR);
    });

    it("새 제안은 옛 제안을 덮어쓴다. 옛 id 취소는 NoPendingRecovery", async function () {
      const f = await loadFixture(deployFixture);
      const first = await proposeRecovery(f, { from: f.president.address, to: f.extra1.address });
      await first.tx;
      const second = await proposeRecovery(f, { from: f.president.address, to: f.extra2.address });
      await second.tx;
      const pending = await f.roleManager.pendingRecovery();
      expect(pending.recoveryId).to.equal(second.recoveryId);
      expect(pending.to).to.equal(f.extra2.address);
      await expect((await cancelRecovery(f, first.recoveryId)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "NoPendingRecovery")
        .withArgs(first.recoveryId);
    });

    it("복구 실행은 nonce 를 올려 그 사이 받아 둔 일반 변경 서명을 무효로 만든다", async function () {
      const f = await loadFixture(deployFixture);
      await proposeAndWait(f, f.extra1.address);
      // 옛 회장이 대기 중에 서명해 둔 일반 변경 (nonce 1)
      const stale = await makeRoleChange(f.roleManager, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra2.address });
      const sP = await signRoleChange(f.president, f.roleManager, stale);
      const sA = await signRoleChange(f.auditor, f.roleManager, stale);
      await f.roleManager.executePresidentRecovery();
      await expect(f.roleManager.connect(f.relayer).changeRole(stale, sP, sA))
        .to.be.revertedWithCustomError(f.roleManager, "InvalidNonce")
        .withArgs(2n, 1n);
    });

    it("대기 중인 복구가 없으면 실행은 NoPendingRecovery", async function () {
      const f = await loadFixture(deployFixture);
      await expect(f.roleManager.executePresidentRecovery())
        .to.be.revertedWithCustomError(f.roleManager, "NoPendingRecovery")
        .withArgs(0n);
    });
  });
});
