import { expect } from "chai";
import {
  ethers,
  time,
  loadFixture,
  deployFixture,
  type Fixture,
  ROLE,
  TERM,
  OTHER_TERM,
  ZERO32,
  ZERO_ADDR,
  Kind,
  ObjectionStatus,
  OBJECTION_TYPES,
  record,
  mintBatch,
  burnMembership,
  raiseObjection,
  signedAnswer,
  answerObjection,
  changeRole,
  textHash,
} from "./helpers/fixture.ts";

const ENTRY = 1n; // TERM 수입 항목 (PENDING)
const OTHER_TERM_ENTRY = 2n; // OTHER_TERM 수입 항목

/** 항목 두 개(학기 TERM·OTHER_TERM)와 TERM 회원권을 가진 학생(extra1). 회원권 없는 학생은 extra2. */
async function objectionFixture() {
  const f = await deployFixture();
  await (await record(f, { id: ENTRY, amount: 10_000n, kind: Kind.INCOME })).tx;
  await (await record(f, { id: OTHER_TERM_ENTRY, amount: 20_000n, kind: Kind.INCOME, term: OTHER_TERM })).tx;
  await (await mintBatch(f, { recipients: [f.extra1.address] })).tx;
  return f;
}

/** 위 상태에서 이의 1번이 OPEN. */
async function raisedFixture() {
  const f = await objectionFixture();
  await raiseObjection(f, { objectionId: 1n, entryId: ENTRY, raiser: f.extra1.address }).tx;
  return f;
}

function answerWithSig(f: Fixture, req: any, sig: string) {
  return f.objectionRegistry.connect(f.relayer).answer(req, sig);
}

describe("ObjectionRegistry", function () {
  describe("배포", function () {
    it("도메인과 연결된 주소", async function () {
      const f = await loadFixture(deployFixture);
      const r = f.objectionRegistry;
      expect(await r.roleManager()).to.equal(f.addresses.RoleManager);
      expect(await r.ledger()).to.equal(f.addresses.AccountingLedger);
      expect(await r.membershipSBT()).to.equal(f.addresses.MembershipSBT);
      expect(await r.relayer()).to.equal(f.relayer.address);
      const { chainId } = await ethers.provider.getNetwork();
      expect(await r.DOMAIN_SEPARATOR()).to.equal(
        ethers.TypedDataEncoder.hashDomain({
          name: "ObjectionRegistry",
          version: "1",
          chainId,
          verifyingContract: f.addresses.ObjectionRegistry,
        }),
      );
    });

    // 맨 뒤에 배포해야 앞의 네 주소(앱·서버 빌드에 박힌 기대값)가 v0.15 배포와 같다
    it("배포 순서: 앞의 네 컨트랙트 주소는 그대로이고 ObjectionRegistry 는 n+5", async function () {
      const f = await loadFixture(deployFixture);
      const n = f.roleManager.deploymentTransaction()!.nonce;
      const at = (i: number) => ethers.getCreateAddress({ from: f.deployer.address, nonce: n + i });
      expect(f.addresses.RoleManager).to.equal(at(0));
      expect(f.addresses.BudgetToken).to.equal(at(1));
      expect(f.addresses.AccountingLedger).to.equal(at(2));
      expect(f.addresses.MembershipSBT).to.equal(at(4));
      expect(f.addresses.ObjectionRegistry).to.equal(at(5));
    });

    it("생성자 인자 중 0 주소가 있으면 ZeroAddress", async function () {
      const f = await loadFixture(deployFixture);
      const factory = await ethers.getContractFactory("ObjectionRegistry");
      const ok = [f.addresses.RoleManager, f.addresses.AccountingLedger, f.addresses.MembershipSBT, f.relayer.address];
      for (let i = 0; i < ok.length; i++) {
        const args = ok.map((a, j) => (j === i ? ZERO_ADDR : a));
        await expect(factory.deploy(...args)).to.be.revertedWithCustomError(f.objectionRegistry, "ZeroAddress");
      }
    });
  });

  describe("제기 (raise)", function () {
    it("릴레이어가 올리면 OPEN 으로 저장되고 ObjectionRaised", async function () {
      const f = await loadFixture(objectionFixture);
      const { contentHash, tx } = raiseObjection(f, { objectionId: 1n, entryId: ENTRY, raiser: f.extra1.address });
      await expect(tx)
        .to.emit(f.objectionRegistry, "ObjectionRaised")
        .withArgs(1n, ENTRY, contentHash, f.extra1.address);

      expect(await f.objectionRegistry.exists(1n)).to.equal(true);
      const o = await f.objectionRegistry.getObjection(1n);
      expect(o.entryId).to.equal(ENTRY);
      expect(o.contentHash).to.equal(contentHash);
      expect(o.answerHash).to.equal(ZERO32);
      expect(o.status).to.equal(ObjectionStatus.OPEN);
      expect(o.raiser).to.equal(f.extra1.address);
      expect(o.responder).to.equal(ZERO_ADDR);
    });

    it("항목 상태를 바꾸지 않는다", async function () {
      const f = await loadFixture(objectionFixture);
      const before = await f.ledger.getEntry(ENTRY);
      await raiseObjection(f, { objectionId: 1n, entryId: ENTRY, raiser: f.extra1.address }).tx;
      const after = await f.ledger.getEntry(ENTRY);
      expect(after.status).to.equal(before.status);
      expect(after.hash).to.equal(before.hash);
    });

    it("릴레이어가 아니면 Unauthorized — 임원·학생 본인도 직접 부를 수 없다", async function () {
      const f = await loadFixture(objectionFixture);
      for (const caller of [f.outsider, f.extra1, f.president, f.auditor, f.deployer]) {
        await expect(raiseObjection(f, { objectionId: 1n, entryId: ENTRY, raiser: f.extra1.address }, caller).tx)
          .to.be.revertedWithCustomError(f.objectionRegistry, "Unauthorized")
          .withArgs(caller.address);
      }
    });

    it("objectionId 0 은 ReservedId", async function () {
      const f = await loadFixture(objectionFixture);
      await expect(
        raiseObjection(f, { objectionId: 0n, entryId: ENTRY, raiser: f.extra1.address }).tx,
      ).to.be.revertedWithCustomError(f.objectionRegistry, "ReservedId");
    });

    it("같은 id 는 ObjectionAlreadyExists", async function () {
      const f = await loadFixture(raisedFixture);
      await expect(raiseObjection(f, { objectionId: 1n, entryId: ENTRY, raiser: f.extra1.address }).tx)
        .to.be.revertedWithCustomError(f.objectionRegistry, "ObjectionAlreadyExists")
        .withArgs(1n);
    });

    it("원장에 없는 항목은 EntryNotFound", async function () {
      const f = await loadFixture(objectionFixture);
      await expect(raiseObjection(f, { objectionId: 1n, entryId: 99n, raiser: f.extra1.address }).tx)
        .to.be.revertedWithCustomError(f.objectionRegistry, "EntryNotFound")
        .withArgs(99n);
    });

    it("회원권이 없으면 NotMember", async function () {
      const f = await loadFixture(objectionFixture);
      await expect(raiseObjection(f, { objectionId: 1n, entryId: ENTRY, raiser: f.extra2.address }).tx)
        .to.be.revertedWithCustomError(f.objectionRegistry, "NotMember")
        .withArgs(f.extra2.address);
    });

    it("회원권은 항목의 학기 기준이다 — 다른 학기 회원권으로는 NotMember", async function () {
      const f = await loadFixture(objectionFixture);
      // extra1 은 TERM 회원권만 있다. OTHER_TERM 항목에는 제기할 수 없다
      await expect(
        raiseObjection(f, { objectionId: 1n, entryId: OTHER_TERM_ENTRY, raiser: f.extra1.address }).tx,
      ).to.be.revertedWithCustomError(f.objectionRegistry, "NotMember");
      await (await mintBatch(f, { recipients: [f.extra1.address], term: OTHER_TERM })).tx;
      await expect(raiseObjection(f, { objectionId: 1n, entryId: OTHER_TERM_ENTRY, raiser: f.extra1.address }).tx).to.emit(
        f.objectionRegistry,
        "ObjectionRaised",
      );
    });

    it("회원권이 소각되면 그 뒤로는 NotMember (이미 올린 이의는 그대로)", async function () {
      const f = await loadFixture(raisedFixture);
      await (await burnMembership(f, { holder: f.extra1.address })).tx;
      await expect(
        raiseObjection(f, { objectionId: 2n, entryId: ENTRY, raiser: f.extra1.address }).tx,
      ).to.be.revertedWithCustomError(f.objectionRegistry, "NotMember");
      expect(await f.objectionRegistry.exists(1n)).to.equal(true);
    });

    it("0 주소 제기자는 NotMember", async function () {
      const f = await loadFixture(objectionFixture);
      await expect(raiseObjection(f, { objectionId: 1n, entryId: ENTRY, raiser: ZERO_ADDR }).tx)
        .to.be.revertedWithCustomError(f.objectionRegistry, "NotMember")
        .withArgs(ZERO_ADDR);
    });

    it("한 항목에 여러 이의, 한 학생이 여러 이의를 올릴 수 있다", async function () {
      const f = await loadFixture(raisedFixture);
      await raiseObjection(f, { objectionId: 2n, entryId: ENTRY, raiser: f.extra1.address }).tx;
      await (await mintBatch(f, { recipients: [f.extra2.address] })).tx;
      await raiseObjection(f, { objectionId: 3n, entryId: ENTRY, raiser: f.extra2.address }).tx;
      expect(await f.objectionRegistry.exists(2n)).to.equal(true);
      expect(await f.objectionRegistry.exists(3n)).to.equal(true);
    });

    it("검사 순서: Unauthorized 가 ReservedId 보다 먼저", async function () {
      const f = await loadFixture(objectionFixture);
      await expect(
        raiseObjection(f, { objectionId: 0n, entryId: 99n, raiser: ZERO_ADDR }, f.outsider).tx,
      ).to.be.revertedWithCustomError(f.objectionRegistry, "Unauthorized");
    });
  });

  describe("답변 (answer)", function () {
    it("감사 서명으로 답변하면 ANSWERED, responder 는 서명자, ObjectionAnswered", async function () {
      const f = await loadFixture(raisedFixture);
      const { req, tx } = await answerObjection(f, { objectionId: 1n });
      await expect(tx)
        .to.emit(f.objectionRegistry, "ObjectionAnswered")
        .withArgs(1n, req.answerHash, f.auditor.address);
      const o = await f.objectionRegistry.getObjection(1n);
      expect(o.status).to.equal(ObjectionStatus.ANSWERED);
      expect(o.answerHash).to.equal(req.answerHash);
      expect(o.responder).to.equal(f.auditor.address);
      expect(o.contentHash).to.equal(textHash("이의:1"));
    });

    it("회장, 두 번째 감사의 서명으로도 답변된다", async function () {
      const f = await loadFixture(raisedFixture);
      await raiseObjection(f, { objectionId: 2n, entryId: ENTRY, raiser: f.extra1.address }).tx;
      await (await answerObjection(f, { objectionId: 1n }, f.president)).tx;
      await (await answerObjection(f, { objectionId: 2n }, f.auditor2)).tx;
      expect((await f.objectionRegistry.getObjection(1n)).responder).to.equal(f.president.address);
      expect((await f.objectionRegistry.getObjection(2n)).responder).to.equal(f.auditor2.address);
    });

    it("누가 보내든 서명자로 판단한다 (외부인이 감사 서명을 제출해도 성공)", async function () {
      const f = await loadFixture(raisedFixture);
      const { req, sig } = await signedAnswer(f, { objectionId: 1n });
      await expect(f.objectionRegistry.connect(f.outsider).answer(req, sig))
        .to.emit(f.objectionRegistry, "ObjectionAnswered")
        .withArgs(1n, req.answerHash, f.auditor.address);
    });

    it("총무·외부인·학생의 서명은 NotResponder", async function () {
      const f = await loadFixture(raisedFixture);
      for (const signer of [f.treasurer, f.outsider, f.extra1, f.relayer]) {
        const { req, sig } = await signedAnswer(f, { objectionId: 1n }, signer);
        await expect(answerWithSig(f, req, sig))
          .to.be.revertedWithCustomError(f.objectionRegistry, "NotResponder")
          .withArgs(signer.address);
      }
    });

    it("롤에서 내려간 옛 감사의 서명은 NotResponder", async function () {
      const f = await loadFixture(raisedFixture);
      const { req, sig } = await signedAnswer(f, { objectionId: 1n });
      await (await changeRole(f, { role: ROLE.AUDITOR, from: f.auditor.address, to: f.outsider.address }, f.president, f.auditor2)).tx;
      await expect(answerWithSig(f, req, sig))
        .to.be.revertedWithCustomError(f.objectionRegistry, "NotResponder")
        .withArgs(f.auditor.address);
    });

    it("서명 시한이 지나면 SignatureExpired", async function () {
      const f = await loadFixture(raisedFixture);
      const deadline = BigInt(await time.latest()) + 60n;
      const { req, sig } = await signedAnswer(f, { objectionId: 1n, deadline });
      await time.increaseTo(deadline + 1n);
      await expect(answerWithSig(f, req, sig))
        .to.be.revertedWithCustomError(f.objectionRegistry, "SignatureExpired")
        .withArgs(deadline);
    });

    it("서명과 다른 값을 보내면 서명자가 달라져 NotResponder (변조)", async function () {
      const f = await loadFixture(raisedFixture);
      const { req, sig } = await signedAnswer(f, { objectionId: 1n });
      const tampered = { ...req, answerHash: textHash("바꾼 답변") };
      await expect(answerWithSig(f, tampered, sig)).to.be.revertedWithCustomError(f.objectionRegistry, "NotResponder");
    });

    it("깨진 서명은 InvalidSignature", async function () {
      const f = await loadFixture(raisedFixture);
      const { req } = await signedAnswer(f, { objectionId: 1n });
      await expect(answerWithSig(f, req, "0x1234")).to.be.revertedWithCustomError(f.objectionRegistry, "InvalidSignature");
    });

    it("다른 컨트랙트 도메인으로 서명하면 통과하지 못한다", async function () {
      const f = await loadFixture(raisedFixture);
      const req = { objectionId: 1n, answerHash: textHash("답변"), deadline: BigInt(await time.latest()) + 3600n };
      const { chainId } = await ethers.provider.getNetwork();
      const sig = await f.auditor.signTypedData(
        { name: "AccountingLedger", version: "1", chainId, verifyingContract: f.addresses.AccountingLedger },
        { AnswerRequest: OBJECTION_TYPES.AnswerRequest },
        req,
      );
      await expect(answerWithSig(f, req, sig)).to.be.revertedWithCustomError(f.objectionRegistry, "NotResponder");
    });

    it("없는 이의는 ObjectionNotFound (id 0 포함)", async function () {
      const f = await loadFixture(raisedFixture);
      for (const id of [0n, 2n]) {
        const { tx } = await answerObjection(f, { objectionId: id });
        await expect(tx).to.be.revertedWithCustomError(f.objectionRegistry, "ObjectionNotFound").withArgs(id);
      }
    });

    it("답변은 한 번뿐 — 같은 서명 재사용도, 다른 답변도 ObjectionAlreadyAnswered", async function () {
      const f = await loadFixture(raisedFixture);
      const first = await answerObjection(f, { objectionId: 1n });
      await (await first.tx).wait();
      await expect(answerWithSig(f, first.req, first.sig))
        .to.be.revertedWithCustomError(f.objectionRegistry, "ObjectionAlreadyAnswered")
        .withArgs(1n);
      const { tx } = await answerObjection(f, { objectionId: 1n, answerHash: textHash("두 번째") }, f.president);
      await expect(tx).to.be.revertedWithCustomError(f.objectionRegistry, "ObjectionAlreadyAnswered");
      expect((await f.objectionRegistry.getObjection(1n)).responder).to.equal(f.auditor.address);
    });

    it("검사 순서: 시한 → 서명 → 권한 → 존재", async function () {
      const f = await loadFixture(raisedFixture);
      // 없는 id + 권한 없는 서명자 → 권한이 먼저
      const bad = await signedAnswer(f, { objectionId: 9n }, f.outsider);
      await expect(answerWithSig(f, bad.req, bad.sig)).to.be.revertedWithCustomError(f.objectionRegistry, "NotResponder");
      // 시한 경과 + 깨진 서명 → 시한이 먼저
      const deadline = BigInt(await time.latest()) - 1n;
      await expect(
        answerWithSig(f, { objectionId: 9n, answerHash: ZERO32, deadline }, "0x"),
      ).to.be.revertedWithCustomError(f.objectionRegistry, "SignatureExpired");
    });
  });

  describe("조회", function () {
    it("없는 id 는 exists false, getObjection 은 빈 구조체 (raiser 0)", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.objectionRegistry.exists(1n)).to.equal(false);
      const o = await f.objectionRegistry.getObjection(1n);
      expect(o.raiser).to.equal(ZERO_ADDR);
      expect(o.entryId).to.equal(0n);
    });
  });

  describe("EIP-712", function () {
    it("AnswerRequest typehash 가 docs/CONTRACTS.md 문자열과 같다", async function () {
      const f = await loadFixture(raisedFixture);
      const { req, sig } = await signedAnswer(f, { objectionId: 1n });
      const digest = ethers.TypedDataEncoder.hash(
        {
          name: "ObjectionRegistry",
          version: "1",
          chainId: (await ethers.provider.getNetwork()).chainId,
          verifyingContract: f.addresses.ObjectionRegistry,
        },
        { AnswerRequest: OBJECTION_TYPES.AnswerRequest },
        req,
      );
      expect(ethers.recoverAddress(digest, sig)).to.equal(f.auditor.address);
      expect(ethers.TypedDataEncoder.from({ AnswerRequest: OBJECTION_TYPES.AnswerRequest }).encodeType("AnswerRequest")).to.equal(
        "AnswerRequest(uint256 objectionId,bytes32 answerHash,uint256 deadline)",
      );
    });
  });
});
