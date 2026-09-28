import { expect } from "chai";
import { ethers, loadFixture, deployFixture, ROLE, ZERO_ADDR, type Fixture } from "./helpers/fixture.ts";
import { gas } from "./helpers/gas.ts";

/** 제안 → 다른 임원 승인까지 한 번에. 정상 경로 세팅용. */
async function change(f: Fixture, proposer: any, approver: any, role: string, from: string, to: string) {
  const id = await f.roleManager.connect(proposer).proposeRoleChange.staticCall(role, from, to);
  await gas("RoleManager.proposeRoleChange", f.roleManager.connect(proposer).proposeRoleChange(role, from, to));
  return { id, approve: () => f.roleManager.connect(approver).approveRoleChange(id) };
}

describe("RoleManager", function () {
  describe("배포 (생성자)", function () {
    it("생성자로 넣은 세 임원이 롤을 갖고, 배포자·릴레이어는 어떤 롤도 없다", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.roleManager.hasRole(ROLE.PRESIDENT, f.president.address)).to.equal(true);
      expect(await f.roleManager.hasRole(ROLE.TREASURER, f.treasurer.address)).to.equal(true);
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.auditor.address)).to.equal(true);
      expect(await f.roleManager.roleOf(f.president.address)).to.equal(ROLE.PRESIDENT);
      expect(await f.roleManager.roleOf(f.treasurer.address)).to.equal(ROLE.TREASURER);
      expect(await f.roleManager.roleOf(f.auditor.address)).to.equal(ROLE.AUDITOR);
      expect(await f.roleManager.officerCount()).to.equal(3n);

      for (const who of [f.deployer, f.relayer, f.outsider]) {
        expect(await f.roleManager.roleOf(who.address)).to.equal(ethers.ZeroHash);
        for (const role of Object.values(ROLE)) {
          expect(await f.roleManager.hasRole(role, who.address)).to.equal(false);
        }
      }
    });

    it("롤 식별자는 이름의 keccak256 이다", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.roleManager.TREASURER()).to.equal(ROLE.TREASURER);
      expect(await f.roleManager.AUDITOR()).to.equal(ROLE.AUDITOR);
      expect(await f.roleManager.PRESIDENT()).to.equal(ROLE.PRESIDENT);
    });

    it("생성자 인자에 0 주소가 있으면 ZeroAddress", async function () {
      const [, p, t] = await ethers.getSigners();
      const factory = await ethers.getContractFactory("RoleManager");
      await expect(factory.deploy(p.address, t.address, ZERO_ADDR)).to.be.revertedWithCustomError(
        factory,
        "ZeroAddress",
      );
    });

    it("생성자 인자가 중복되면 AlreadyOfficer (한 주소 한 롤)", async function () {
      const [, p, t] = await ethers.getSigners();
      const factory = await ethers.getContractFactory("RoleManager");
      await expect(factory.deploy(p.address, t.address, t.address))
        .to.be.revertedWithCustomError(factory, "AlreadyOfficer")
        .withArgs(t.address, ROLE.TREASURER);
    });
  });

  describe("제안 (proposeRoleChange)", function () {
    it("임원이 아닌 계정의 제안은 Unauthorized", async function () {
      const f = await loadFixture(deployFixture);
      for (const who of [f.outsider, f.relayer, f.deployer]) {
        await expect(f.roleManager.connect(who).proposeRoleChange(ROLE.AUDITOR, ZERO_ADDR, f.extra1.address))
          .to.be.revertedWithCustomError(f.roleManager, "Unauthorized")
          .withArgs(who.address);
      }
    });

    it("세 롤 외의 role 은 UnknownRole", async function () {
      const f = await loadFixture(deployFixture);
      const bogus = ethers.keccak256(ethers.toUtf8Bytes("STUDENT"));
      await expect(f.roleManager.connect(f.president).proposeRoleChange(bogus, ZERO_ADDR, f.extra1.address))
        .to.be.revertedWithCustomError(f.roleManager, "UnknownRole")
        .withArgs(bogus);
    });

    it("from·to 가 둘 다 0 이면 ZeroAddress", async function () {
      const f = await loadFixture(deployFixture);
      await expect(
        f.roleManager.connect(f.president).proposeRoleChange(ROLE.AUDITOR, ZERO_ADDR, ZERO_ADDR),
      ).to.be.revertedWithCustomError(f.roleManager, "ZeroAddress");
    });

    it("제안은 1 부터 번호가 붙고 RoleChangeProposed 를 낸다. 실행 전 상태는 바뀌지 않는다", async function () {
      const f = await loadFixture(deployFixture);
      await expect(f.roleManager.connect(f.treasurer).proposeRoleChange(ROLE.AUDITOR, ZERO_ADDR, f.extra1.address))
        .to.emit(f.roleManager, "RoleChangeProposed")
        .withArgs(1n, ROLE.AUDITOR, ZERO_ADDR, f.extra1.address, f.treasurer.address);

      const c = await f.roleManager.getRoleChange(1n);
      expect(c.role).to.equal(ROLE.AUDITOR);
      expect(c.from).to.equal(ZERO_ADDR);
      expect(c.to).to.equal(f.extra1.address);
      expect(c.proposer).to.equal(f.treasurer.address);
      expect(c.executed).to.equal(false);

      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.extra1.address)).to.equal(false);
      expect(await f.roleManager.officerCount()).to.equal(3n);
    });
  });

  describe("승인 (approveRoleChange) — 필수 테스트 9: 서로 다른 두 임원 없이는 실행되지 않는다", function () {
    it("없는 제안은 ChangeNotFound", async function () {
      const f = await loadFixture(deployFixture);
      await expect(f.roleManager.connect(f.president).approveRoleChange(7n))
        .to.be.revertedWithCustomError(f.roleManager, "ChangeNotFound")
        .withArgs(7n);
    });

    it("제안자 본인이 승인하면 SelfApproval 이고 상태는 그대로다", async function () {
      const f = await loadFixture(deployFixture);
      const { id } = await change(f, f.treasurer, f.treasurer, ROLE.AUDITOR, ZERO_ADDR, f.extra1.address);
      await expect(f.roleManager.connect(f.treasurer).approveRoleChange(id))
        .to.be.revertedWithCustomError(f.roleManager, "SelfApproval")
        .withArgs(id);
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.extra1.address)).to.equal(false);
    });

    it("임원이 아닌 계정의 승인은 Unauthorized 이고 상태는 그대로다", async function () {
      const f = await loadFixture(deployFixture);
      const { id } = await change(f, f.treasurer, f.outsider, ROLE.AUDITOR, ZERO_ADDR, f.extra1.address);
      for (const who of [f.outsider, f.relayer, f.deployer, f.extra1]) {
        await expect(f.roleManager.connect(who).approveRoleChange(id))
          .to.be.revertedWithCustomError(f.roleManager, "Unauthorized")
          .withArgs(who.address);
      }
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.extra1.address)).to.equal(false);
    });

    it("한 번 실행된 제안은 ChangeAlreadyExecuted", async function () {
      const f = await loadFixture(deployFixture);
      const { id, approve } = await change(f, f.treasurer, f.president, ROLE.AUDITOR, ZERO_ADDR, f.extra1.address);
      await approve();
      await expect(f.roleManager.connect(f.auditor).approveRoleChange(id))
        .to.be.revertedWithCustomError(f.roleManager, "ChangeAlreadyExecuted")
        .withArgs(id);
    });

    it("승인 시점에 제안자가 더는 임원이 아니면 ProposerNotOfficer", async function () {
      const f = await loadFixture(deployFixture);
      // 감사가 X 를 제안해 둔다
      const x = await change(f, f.auditor, f.president, ROLE.AUDITOR, ZERO_ADDR, f.extra1.address);
      // 그 사이 회장 제안·총무 승인으로 감사를 회수 (3 → 2 명)
      const r = await change(f, f.president, f.treasurer, ROLE.AUDITOR, f.auditor.address, ZERO_ADDR);
      await r.approve();
      expect(await f.roleManager.officerCount()).to.equal(2n);
      // 회장이 X 를 승인하려 하면 제안자(감사)가 이미 임원이 아님
      await expect(x.approve())
        .to.be.revertedWithCustomError(f.roleManager, "ProposerNotOfficer")
        .withArgs(x.id, f.auditor.address);
    });
  });

  describe("부여 (from == 0)", function () {
    it("다른 임원이 승인하면 실행되고 RoleGranted 에 제안자·승인자가 남는다", async function () {
      const f = await loadFixture(deployFixture);
      const { id, approve } = await change(f, f.treasurer, f.president, ROLE.AUDITOR, ZERO_ADDR, f.extra1.address);
      const tx = gas("RoleManager.approveRoleChange (grant)", approve());
      await expect(tx)
        .to.emit(f.roleManager, "RoleChangeApproved")
        .withArgs(id, f.president.address)
        .and.to.emit(f.roleManager, "RoleGranted")
        .withArgs(ROLE.AUDITOR, f.extra1.address, f.treasurer.address, f.president.address)
        .and.not.to.emit(f.roleManager, "RoleReplaced");

      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.extra1.address)).to.equal(true);
      expect(await f.roleManager.roleOf(f.extra1.address)).to.equal(ROLE.AUDITOR);
      expect(await f.roleManager.officerCount()).to.equal(4n);
      expect((await f.roleManager.getRoleChange(id)).executed).to.equal(true);
    });

    it("이미 같은 롤을 가진 주소에 부여하면 RoleAlreadyGranted", async function () {
      const f = await loadFixture(deployFixture);
      const { approve } = await change(f, f.treasurer, f.president, ROLE.AUDITOR, ZERO_ADDR, f.auditor.address);
      await expect(approve())
        .to.be.revertedWithCustomError(f.roleManager, "RoleAlreadyGranted")
        .withArgs(ROLE.AUDITOR, f.auditor.address);
    });

    it("이미 다른 임원 롤을 가진 주소에 부여하면 AlreadyOfficer (한 주소 한 롤)", async function () {
      const f = await loadFixture(deployFixture);
      const { approve } = await change(f, f.auditor, f.president, ROLE.AUDITOR, ZERO_ADDR, f.treasurer.address);
      await expect(approve())
        .to.be.revertedWithCustomError(f.roleManager, "AlreadyOfficer")
        .withArgs(f.treasurer.address, ROLE.TREASURER);
    });
  });

  describe("회수 (to == 0)", function () {
    it("다른 임원이 승인하면 실행되고 RoleRevoked 에 제안자·승인자가 남는다. 3 → 2 명은 허용", async function () {
      const f = await loadFixture(deployFixture);
      const { id, approve } = await change(f, f.president, f.treasurer, ROLE.AUDITOR, f.auditor.address, ZERO_ADDR);
      await expect(gas("RoleManager.approveRoleChange (revoke)", approve()))
        .to.emit(f.roleManager, "RoleChangeApproved")
        .withArgs(id, f.treasurer.address)
        .and.to.emit(f.roleManager, "RoleRevoked")
        .withArgs(ROLE.AUDITOR, f.auditor.address, f.president.address, f.treasurer.address)
        .and.not.to.emit(f.roleManager, "RoleReplaced");

      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.auditor.address)).to.equal(false);
      expect(await f.roleManager.roleOf(f.auditor.address)).to.equal(ethers.ZeroHash);
      expect(await f.roleManager.officerCount()).to.equal(2n);
    });

    it("회수 결과 임원이 2 명 미만이 되면 TooFewOfficers", async function () {
      const f = await loadFixture(deployFixture);
      const r1 = await change(f, f.president, f.treasurer, ROLE.AUDITOR, f.auditor.address, ZERO_ADDR);
      await r1.approve(); // 2 명
      const r2 = await change(f, f.president, f.treasurer, ROLE.TREASURER, f.treasurer.address, ZERO_ADDR);
      await expect(r2.approve())
        .to.be.revertedWithCustomError(f.roleManager, "TooFewOfficers")
        .withArgs(1n, 2n);
      expect(await f.roleManager.hasRole(ROLE.TREASURER, f.treasurer.address)).to.equal(true);
    });

    it("롤을 갖고 있지 않은 from 을 회수하면 RoleNotGranted", async function () {
      const f = await loadFixture(deployFixture);
      const { approve } = await change(f, f.president, f.treasurer, ROLE.AUDITOR, f.extra1.address, ZERO_ADDR);
      await expect(approve())
        .to.be.revertedWithCustomError(f.roleManager, "RoleNotGranted")
        .withArgs(ROLE.AUDITOR, f.extra1.address);
    });

    it("from 이 다른 롤을 갖고 있어도 지정한 role 이 아니면 RoleNotGranted", async function () {
      const f = await loadFixture(deployFixture);
      const { approve } = await change(f, f.president, f.treasurer, ROLE.AUDITOR, f.treasurer.address, ZERO_ADDR);
      await expect(approve())
        .to.be.revertedWithCustomError(f.roleManager, "RoleNotGranted")
        .withArgs(ROLE.AUDITOR, f.treasurer.address);
    });
  });

  describe("교체 (from != 0 && to != 0)", function () {
    it("실행되면 RoleRevoked + RoleGranted + RoleReplaced 를 내고 임원 수는 그대로다", async function () {
      const f = await loadFixture(deployFixture);
      const { id, approve } = await change(
        f,
        f.president,
        f.auditor,
        ROLE.TREASURER,
        f.treasurer.address,
        f.extra2.address,
      );
      await expect(gas("RoleManager.approveRoleChange (replace)", approve()))
        .to.emit(f.roleManager, "RoleChangeApproved")
        .withArgs(id, f.auditor.address)
        .and.to.emit(f.roleManager, "RoleRevoked")
        .withArgs(ROLE.TREASURER, f.treasurer.address, f.president.address, f.auditor.address)
        .and.to.emit(f.roleManager, "RoleGranted")
        .withArgs(ROLE.TREASURER, f.extra2.address, f.president.address, f.auditor.address)
        .and.to.emit(f.roleManager, "RoleReplaced")
        .withArgs(ROLE.TREASURER, f.treasurer.address, f.extra2.address, f.president.address, f.auditor.address);

      expect(await f.roleManager.hasRole(ROLE.TREASURER, f.treasurer.address)).to.equal(false);
      expect(await f.roleManager.hasRole(ROLE.TREASURER, f.extra2.address)).to.equal(true);
      expect(await f.roleManager.officerCount()).to.equal(3n);
    });

    it("from == to 는 RoleAlreadyGranted", async function () {
      const f = await loadFixture(deployFixture);
      const { approve } = await change(
        f,
        f.president,
        f.auditor,
        ROLE.TREASURER,
        f.treasurer.address,
        f.treasurer.address,
      );
      await expect(approve())
        .to.be.revertedWithCustomError(f.roleManager, "RoleAlreadyGranted")
        .withArgs(ROLE.TREASURER, f.treasurer.address);
    });

    it("교체 대상 to 가 다른 임원 롤을 갖고 있으면 AlreadyOfficer", async function () {
      const f = await loadFixture(deployFixture);
      const { approve } = await change(
        f,
        f.president,
        f.auditor,
        ROLE.TREASURER,
        f.treasurer.address,
        f.auditor.address,
      );
      await expect(approve())
        .to.be.revertedWithCustomError(f.roleManager, "AlreadyOfficer")
        .withArgs(f.auditor.address, ROLE.AUDITOR);
    });

    it("한계: 총무가 참여한 2 인 승인으로 감사를 교체할 수 있다 (이벤트로 남는다)", async function () {
      const f = await loadFixture(deployFixture);
      const { approve } = await change(f, f.treasurer, f.president, ROLE.AUDITOR, f.auditor.address, f.extra1.address);
      await expect(approve())
        .to.emit(f.roleManager, "RoleReplaced")
        .withArgs(ROLE.AUDITOR, f.auditor.address, f.extra1.address, f.treasurer.address, f.president.address);
      expect(await f.roleManager.hasRole(ROLE.AUDITOR, f.extra1.address)).to.equal(true);
    });
  });
});
