import { expect } from "chai";
import {
  ethers,
  time,
  loadFixture,
  deployFixture,
  ROLE,
  ZERO_ADDR,
  changeRole,
  makeRoleChange,
  signRoleChange,
} from "./helpers/fixture.ts";
import { gas } from "./helpers/gas.ts";

describe("RoleManager", function () {
  describe("배포 (생성자)", function () {
    it("생성자로 넣은 세 임원이 롤을 갖고, 배포자·릴레이어는 어떤 롤도 없다", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.president.address)).to.equal(true);
      expect(await f.roleManager.hasRole(ROLE.TREASURER, f.treasurer.address)).to.equal(true);
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.auditor.address)).to.equal(true);
      expect(await f.roleManager.roleOf(f.president.address)).to.equal(ROLE.PRESIDENT);
      for (const role of Object.values(ROLE)) {
        expect(await f.roleManager.holderCount(role)).to.equal(1n);
      }
      expect(await f.roleManager.nonce()).to.equal(0n);

      for (const who of [f.deployer, f.relayer, f.outsider]) {
        expect(await f.roleManager.roleOf(who.address)).to.equal(ethers.ZeroHash);
        expect(await f.roleManager.isGovernor(who.address)).to.equal(false);
        for (const role of Object.values(ROLE)) {
          expect(await f.roleManager.hasRole(role, who.address)).to.equal(false);
        }
      }
    });

    it("거버너는 회장·감사뿐이다. 총무는 거버너가 아니다", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.roleManager.isGovernor(f.president.address)).to.equal(true);
      expect(await f.roleManager.isGovernor(f.auditor.address)).to.equal(true);
      expect(await f.roleManager.isGovernor(f.treasurer.address)).to.equal(false);
    });

    it("생성자 부여 이벤트는 proposer·approver 가 0 이다 (최초 부여 표시)", async function () {
      const f = await loadFixture(deployFixture);
      const logs = await f.roleManager.queryFilter(f.roleManager.filters.RoleGranted());
      expect(logs.length).to.equal(3);
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
        ethers.TypedDataEncoder.hashDomain({
          name: "RoleManager",
          version: "1",
          chainId,
          verifyingContract: f.addresses.RoleManager,
        }),
      );
    });

    it("생성자 인자에 0 주소가 있으면 ZeroAddress, 중복이면 AlreadyOfficer", async function () {
      const [, p, t] = await ethers.getSigners();
      const factory = await ethers.getContractFactory("RoleManager");
      await expect(factory.deploy(p.address, t.address, ZERO_ADDR)).to.be.revertedWithCustomError(
        factory,
        "ZeroAddress",
      );
      await expect(factory.deploy(p.address, t.address, t.address))
        .to.be.revertedWithCustomError(factory, "AlreadyOfficer")
        .withArgs(t.address, ROLE.TREASURER);
    });
  });

  describe("필수 테스트 9: 서로 다른 두 거버너의 서명 없이는 실행되지 않는다", function () {
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
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.extra1.address)).to.equal(false);
      expect(await f.roleManager.nonce()).to.equal(0n);
    });

    it("한계였던 공격 경로: 총무가 자기 두 번째 키를 감사로 올릴 수 없다", async function () {
      const f = await loadFixture(deployFixture);
      // 총무 + 회장 합의로도 불가 (총무가 거버너가 아님)
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address }, f.treasurer, f.president)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "NotGovernor")
        .withArgs(f.treasurer.address);
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
      // 두 변경에 대한 서명을 같은 nonce(0) 로 받아 둔다
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
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.extra2.address)).to.equal(false);
    });

    it("세 롤 외의 role 은 UnknownRole, from·to 둘 다 0 이면 ZeroAddress", async function () {
      const f = await loadFixture(deployFixture);
      const bogus = ethers.keccak256(ethers.toUtf8Bytes("STUDENT"));
      await expect((await changeRole(f, { role: bogus, from: ZERO_ADDR, to: f.extra1.address }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "UnknownRole")
        .withArgs(bogus);
      await expect(
        (await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: ZERO_ADDR }, f.president, f.auditor)).tx,
      ).to.be.revertedWithCustomError(f.roleManager, "ZeroAddress");
    });
  });

  describe("부여 (from == 0)", function () {
    it("감사는 여럿 둘 수 있다. RoleGranted·RoleChangeExecuted 에 제안자·승인자가 남는다", async function () {
      const f = await loadFixture(deployFixture);
      const { tx } = await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address }, f.president, f.auditor);
      await expect(gas("RoleManager.changeRole (grant)", tx))
        .to.emit(f.roleManager, "RoleGranted")
        .withArgs(ROLE.AUDITOR, f.extra1.address, f.president.address, f.auditor.address)
        .and.to.emit(f.roleManager, "RoleChangeExecuted")
        .withArgs(0n, ROLE.AUDITOR, ZERO_ADDR, f.extra1.address, f.president.address, f.auditor.address)
        .and.not.to.emit(f.roleManager, "RoleRevoked");

      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.extra1.address)).to.equal(true);
      expect(await f.roleManager.holderCount(ROLE.AUDITOR)).to.equal(2n);
      expect(await f.roleManager.isGovernor(f.extra1.address)).to.equal(true);
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
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.auditor.address }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "RoleAlreadyGranted")
        .withArgs(ROLE.AUDITOR, f.auditor.address);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.treasurer.address }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "AlreadyOfficer")
        .withArgs(f.treasurer.address, ROLE.TREASURER);
    });
  });

  describe("회수 (to == 0)", function () {
    it("감사 둘 중 하나는 회수할 수 있고 RoleRevoked 에 제안자·승인자가 남는다", async function () {
      const f = await loadFixture(deployFixture);
      await (await changeRole(f, { role: ROLE.AUDITOR, from: ZERO_ADDR, to: f.extra1.address }, f.president, f.auditor)).tx;
      const { tx } = await changeRole(f, { role: ROLE.AUDITOR, from: f.auditor.address, to: ZERO_ADDR }, f.president, f.extra1);
      await expect(gas("RoleManager.changeRole (revoke)", tx))
        .to.emit(f.roleManager, "RoleRevoked")
        .withArgs(ROLE.AUDITOR, f.auditor.address, f.president.address, f.extra1.address)
        .and.not.to.emit(f.roleManager, "RoleGranted");
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.auditor.address)).to.equal(false);
      expect(await f.roleManager.holderCount(ROLE.AUDITOR)).to.equal(1n);
    });

    it("마지막 감사, 회장, 총무는 회수할 수 없다 (RoleMinimumViolated)", async function () {
      const f = await loadFixture(deployFixture);
      const cases: Array<[string, string]> = [
        [ROLE.AUDITOR, f.auditor.address],
        [ROLE.PRESIDENT, f.president.address],
        [ROLE.TREASURER, f.treasurer.address],
      ];
      for (const [role, holder] of cases) {
        await expect((await changeRole(f, { role, from: holder, to: ZERO_ADDR }, f.president, f.auditor)).tx)
          .to.be.revertedWithCustomError(f.roleManager, "RoleMinimumViolated")
          .withArgs(role);
      }
    });

    it("롤을 갖고 있지 않은 from 을 회수하면 RoleNotGranted", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: f.extra1.address, to: ZERO_ADDR }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "RoleNotGranted")
        .withArgs(ROLE.AUDITOR, f.extra1.address);
      await expect((await changeRole(f, { role: ROLE.AUDITOR, from: f.treasurer.address, to: ZERO_ADDR }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "RoleNotGranted")
        .withArgs(ROLE.AUDITOR, f.treasurer.address);
    });
  });

  describe("교체 (from != 0 && to != 0)", function () {
    it("총무 교체: RoleRevoked + RoleGranted + RoleChangeExecuted, 보유자 수 불변", async function () {
      const f = await loadFixture(deployFixture);
      const { tx } = await changeRole(
        f,
        { role: ROLE.TREASURER, from: f.treasurer.address, to: f.extra2.address },
        f.president,
        f.auditor,
      );
      await expect(gas("RoleManager.changeRole (replace)", tx))
        .to.emit(f.roleManager, "RoleRevoked")
        .withArgs(ROLE.TREASURER, f.treasurer.address, f.president.address, f.auditor.address)
        .and.to.emit(f.roleManager, "RoleGranted")
        .withArgs(ROLE.TREASURER, f.extra2.address, f.president.address, f.auditor.address)
        .and.to.emit(f.roleManager, "RoleChangeExecuted")
        .withArgs(0n, ROLE.TREASURER, f.treasurer.address, f.extra2.address, f.president.address, f.auditor.address);
      expect(await f.roleManager.hasRole(ROLE.TREASURER, f.extra2.address)).to.equal(true);
      expect(await f.roleManager.holderCount(ROLE.TREASURER)).to.equal(1n);
    });

    it("회장 교체 (키 분실): 감사가 제안하고 나가는 회장이 승인해도 된다", async function () {
      const f = await loadFixture(deployFixture);
      await (await changeRole(f, { role: ROLE.PRESIDENT, from: f.president.address, to: f.extra1.address }, f.auditor, f.president)).tx;
      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.extra1.address)).to.equal(true);
      expect(await f.roleManager.isGovernor(f.president.address)).to.equal(false);
      expect(await f.roleManager.holderCount(ROLE.PRESIDENT)).to.equal(1n);
    });

    it("from == to 는 RoleAlreadyGranted, to 가 다른 임원이면 AlreadyOfficer", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await changeRole(f, { role: ROLE.TREASURER, from: f.treasurer.address, to: f.treasurer.address }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "RoleAlreadyGranted")
        .withArgs(ROLE.TREASURER, f.treasurer.address);
      await expect((await changeRole(f, { role: ROLE.TREASURER, from: f.treasurer.address, to: f.auditor.address }, f.president, f.auditor)).tx)
        .to.be.revertedWithCustomError(f.roleManager, "AlreadyOfficer")
        .withArgs(f.auditor.address, ROLE.AUDITOR);
    });
  });
});
