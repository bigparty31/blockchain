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
  ZERO_ADDR,
  BurnReason,
  SBT_TYPES,
  mintBatch,
  burnMembership,
  signedMint,
  signedBurn,
  signMintBatch,
  signBurn,
  changeRole,
  deadlineIn,
} from "./helpers/fixture.ts";
import { gas } from "./helpers/gas.ts";

/** 서로 다른 학생 지갑 n개. 키가 필요 없으므로 무작위 주소로 만든다. */
function wallets(n: number): string[] {
  return Array.from({ length: n }, () => ethers.Wallet.createRandom().address);
}

/** 서명은 그대로 두고 요청 값만 바꿔 보낸다 (변조). */
async function mintWithSig(f: Fixture, req: any, sig: string) {
  return f.membershipSBT.connect(f.relayer).mintBatchRelayed(req, sig);
}

async function burnWithSig(f: Fixture, req: any, sig: string) {
  return f.membershipSBT.connect(f.relayer).burnRelayed(req, sig);
}

/** extra1 이 TERM 회원권 1번을 가진 상태 (회장 서명). */
async function mintedFixture() {
  const f = await deployFixture();
  await (await mintBatch(f, { recipients: [f.extra1.address] })).tx;
  return f;
}

describe("MembershipSBT", function () {
  describe("배포", function () {
    it("이름·도메인·상한·RoleManager 연결", async function () {
      const f = await loadFixture(deployFixture);
      const sbt = f.membershipSBT;
      expect(await sbt.name()).to.equal("MembershipSBT");
      expect(await sbt.MAX_BATCH_SIZE()).to.equal(100n);
      expect(await sbt.roleManager()).to.equal(f.addresses.RoleManager);
      const { chainId } = await ethers.provider.getNetwork();
      expect(await sbt.DOMAIN_SEPARATOR()).to.equal(
        ethers.TypedDataEncoder.hashDomain({
          name: "MembershipSBT",
          version: "1",
          chainId,
          verifyingContract: f.addresses.MembershipSBT,
        }),
      );
    });

    // 주소는 배포자 nonce 로 정해진다. SBT 를 setLedger 뒤에 두어야 앞의 세 주소(앱·서버 벡터에 박힌 값)가 그대로다.
    // 새 노드에서는 n = 0 이고, 다른 테스트가 먼저 배포했으면 그만큼 밀린다.
    it("배포 순서: RoleManager n, BudgetToken n+1, AccountingLedger n+2, setLedger n+3, MembershipSBT n+4", async function () {
      const f = await loadFixture(deployFixture);
      const n = f.roleManager.deploymentTransaction()!.nonce;
      const at = (i: number) => ethers.getCreateAddress({ from: f.deployer.address, nonce: n + i });
      expect(f.addresses.RoleManager).to.equal(at(0));
      expect(f.addresses.BudgetToken).to.equal(at(1));
      expect(f.addresses.AccountingLedger).to.equal(at(2));
      expect(f.addresses.MembershipSBT).to.equal(at(4));
    });

    it("RoleManager 0 주소는 ZeroAddress", async function () {
      const f = await loadFixture(deployFixture);
      const factory = await ethers.getContractFactory("MembershipSBT");
      await expect(factory.deploy(ZERO_ADDR)).to.be.revertedWithCustomError(f.membershipSBT, "ZeroAddress");
    });

    it("ERC721·ERC165 인터페이스를 알린다", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.membershipSBT.supportsInterface("0x80ac58cd")).to.equal(true); // ERC721
      expect(await f.membershipSBT.supportsInterface("0x01ffc9a7")).to.equal(true); // ERC165
      expect(await f.membershipSBT.supportsInterface("0xffffffff")).to.equal(false);
    });
  });

  describe("서명자 권한", function () {
    it("회장 서명으로 발행, 이벤트 actor 는 서명자이고 보낸 사람(릴레이어)은 롤이 없다", async function () {
      const f = await loadFixture(deployFixture);
      expect(await f.roleManager.roleOf(f.relayer.address)).to.equal(ethers.ZeroHash);
      const { tx } = await mintBatch(f, { recipients: [f.extra1.address] });
      await expect(tx)
        .to.emit(f.membershipSBT, "MembershipMinted")
        .withArgs(1n, f.extra1.address, TERM, f.president.address);
      expect(await f.membershipSBT.ownerOf(1n)).to.equal(f.extra1.address);
      expect(await f.membershipSBT.balanceOf(f.extra1.address)).to.equal(1n);
      expect(await f.membershipSBT.tokenOf(f.extra1.address, TERM)).to.equal(1n);
      expect(await f.membershipSBT.hasValidMembership(f.extra1.address, TERM)).to.equal(true);
    });

    it("감사 두 명 각각의 서명으로도 발행·소각된다", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await mintBatch(f, { recipients: [f.extra1.address] }, f.auditor)).tx)
        .to.emit(f.membershipSBT, "MembershipMinted")
        .withArgs(1n, f.extra1.address, TERM, f.auditor.address);
      await expect((await burnMembership(f, { holder: f.extra1.address }, f.auditor2)).tx)
        .to.emit(f.membershipSBT, "MembershipBurned")
        .withArgs(1n, f.extra1.address, TERM, BurnReason.REFUND, f.auditor2.address);
    });

    it("누가 보내든 서명자로 판단한다 (외부인이 회장 서명을 제출해도 성공)", async function () {
      const f = await loadFixture(deployFixture);
      const { req, sig } = await signedMint(f, { recipients: [f.extra1.address] });
      await expect(f.membershipSBT.connect(f.outsider).mintBatchRelayed(req, sig))
        .to.emit(f.membershipSBT, "MembershipMinted")
        .withArgs(1n, f.extra1.address, TERM, f.president.address);
    });

    for (const who of ["treasurer", "outsider", "relayer"] as const) {
      it(`${who} 서명은 발행·소각 모두 NotApprover`, async function () {
        const f = await loadFixture(mintedFixture);
        const signer = f[who];
        await expect((await mintBatch(f, { recipients: [f.extra2.address] }, signer)).tx)
          .to.be.revertedWithCustomError(f.membershipSBT, "NotApprover")
          .withArgs(signer.address);
        await expect((await burnMembership(f, { holder: f.extra1.address }, signer)).tx)
          .to.be.revertedWithCustomError(f.membershipSBT, "NotApprover")
          .withArgs(signer.address);
      });
    }

    it("롤에서 내려간 옛 회장의 서명은 NotApprover", async function () {
      const f = await loadFixture(deployFixture);
      await (await changeRole(f, { role: ROLE.PRESIDENT, from: f.president.address, to: f.outsider.address }, f.president, f.auditor)).tx;
      await expect((await mintBatch(f, { recipients: [f.extra1.address] }, f.president)).tx)
        .to.be.revertedWithCustomError(f.membershipSBT, "NotApprover")
        .withArgs(f.president.address);
      await expect((await mintBatch(f, { recipients: [f.extra1.address] }, f.outsider)).tx).to.emit(
        f.membershipSBT,
        "MembershipMinted",
      );
    });
  });

  describe("배치", function () {
    it("빈 배열은 EmptyBatch", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await mintBatch(f, { recipients: [] })).tx).to.be.revertedWithCustomError(
        f.membershipSBT,
        "EmptyBatch",
      );
    });

    it("100명은 한 번에 발행되고 tokenId 는 1~100", async function () {
      const f = await loadFixture(deployFixture);
      const recipients = wallets(100);
      await gas("MembershipSBT.mintBatchRelayed(100)", (await mintBatch(f, { recipients })).tx);
      expect(await f.membershipSBT.tokenOf(recipients[0], TERM)).to.equal(1n);
      expect(await f.membershipSBT.tokenOf(recipients[99], TERM)).to.equal(100n);
      expect(await f.membershipSBT.nonces(f.president.address)).to.equal(1n);
    });

    it("101명은 BatchTooLarge", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await mintBatch(f, { recipients: wallets(101) })).tx)
        .to.be.revertedWithCustomError(f.membershipSBT, "BatchTooLarge")
        .withArgs(101n);
    });

    it("중간에 0 주소가 있으면 배치 전체가 ZeroAddress 로 revert, nonce 도 그대로", async function () {
      const f = await loadFixture(deployFixture);
      const [a, b] = wallets(2);
      await expect((await mintBatch(f, { recipients: [a, ZERO_ADDR, b] })).tx).to.be.revertedWithCustomError(
        f.membershipSBT,
        "ZeroAddress",
      );
      expect(await f.membershipSBT.hasValidMembership(a, TERM)).to.equal(false);
      expect(await f.membershipSBT.nonces(f.president.address)).to.equal(0n);
    });
  });

  describe("건너뛰기 (한 학기 한 장)", function () {
    it("이미 유효한 수령자는 MembershipSkipped, 새 수령자만 MembershipMinted", async function () {
      const f = await loadFixture(mintedFixture);
      const tx = (await mintBatch(f, { recipients: [f.extra1.address, f.extra2.address] })).tx;
      await expect(tx)
        .to.emit(f.membershipSBT, "MembershipSkipped")
        .withArgs(f.extra1.address, TERM, f.president.address);
      await expect(tx)
        .to.emit(f.membershipSBT, "MembershipMinted")
        .withArgs(2n, f.extra2.address, TERM, f.president.address);
      expect(await f.membershipSBT.tokenOf(f.extra1.address, TERM)).to.equal(1n); // 기존 그대로
      expect(await f.membershipSBT.balanceOf(f.extra1.address)).to.equal(1n);
    });

    it("같은 배치 안의 중복 수령자도 한 장만 받는다", async function () {
      const f = await loadFixture(deployFixture);
      const tx = (await mintBatch(f, { recipients: [f.extra1.address, f.extra1.address] })).tx;
      const receipt = await (await tx).wait();
      const names = receipt.logs
        .map((l: any) => f.membershipSBT.interface.parseLog(l)?.name)
        .filter((n: string | undefined) => n === "MembershipMinted" || n === "MembershipSkipped");
      expect(names).to.deep.equal(["MembershipMinted", "MembershipSkipped"]);
      expect(await f.membershipSBT.balanceOf(f.extra1.address)).to.equal(1n);
    });

    it("전부 건너뛰어도 nonce 를 쓴다", async function () {
      const f = await loadFixture(mintedFixture);
      expect(await f.membershipSBT.nonces(f.president.address)).to.equal(1n);
      const tx = (await mintBatch(f, { recipients: [f.extra1.address] })).tx;
      await expect(tx).to.emit(f.membershipSBT, "MembershipSkipped");
      await expect(tx).not.to.emit(f.membershipSBT, "MembershipMinted");
      expect(await f.membershipSBT.nonces(f.president.address)).to.equal(2n);
    });

    it("다른 학기는 별도 회원권이다", async function () {
      const f = await loadFixture(mintedFixture);
      await expect((await mintBatch(f, { recipients: [f.extra1.address], term: OTHER_TERM })).tx)
        .to.emit(f.membershipSBT, "MembershipMinted")
        .withArgs(2n, f.extra1.address, OTHER_TERM, f.president.address);
      expect(await f.membershipSBT.hasValidMembership(f.extra1.address, TERM)).to.equal(true);
      expect(await f.membershipSBT.hasValidMembership(f.extra1.address, OTHER_TERM)).to.equal(true);
      expect(await f.membershipSBT.balanceOf(f.extra1.address)).to.equal(2n);
      // 한 학기를 소각해도 다른 학기는 남는다
      await (await burnMembership(f, { holder: f.extra1.address, term: TERM })).tx;
      expect(await f.membershipSBT.hasValidMembership(f.extra1.address, TERM)).to.equal(false);
      expect(await f.membershipSBT.hasValidMembership(f.extra1.address, OTHER_TERM)).to.equal(true);
    });
  });

  describe("입력 검사", function () {
    it("발행·소각의 term == 0 은 TermRequired", async function () {
      const f = await loadFixture(mintedFixture);
      await expect((await mintBatch(f, { recipients: [f.extra2.address], term: 0n })).tx).to.be.revertedWithCustomError(
        f.membershipSBT,
        "TermRequired",
      );
      await expect((await burnMembership(f, { holder: f.extra1.address, term: 0n })).tx).to.be.revertedWithCustomError(
        f.membershipSBT,
        "TermRequired",
      );
    });

    it("소각 대상 0 주소는 ZeroAddress", async function () {
      const f = await loadFixture(mintedFixture);
      await expect((await burnMembership(f, { holder: ZERO_ADDR })).tx).to.be.revertedWithCustomError(
        f.membershipSBT,
        "ZeroAddress",
      );
    });

    it("없는 회원권 소각은 NoMembership (다른 학기도)", async function () {
      const f = await loadFixture(mintedFixture);
      await expect((await burnMembership(f, { holder: f.extra2.address })).tx)
        .to.be.revertedWithCustomError(f.membershipSBT, "NoMembership")
        .withArgs(f.extra2.address, TERM);
      await expect((await burnMembership(f, { holder: f.extra1.address, term: OTHER_TERM })).tx)
        .to.be.revertedWithCustomError(f.membershipSBT, "NoMembership")
        .withArgs(f.extra1.address, OTHER_TERM);
    });

    for (const reason of [2, 255]) {
      it(`범위 밖 reason ${reason} 은 InvalidBurnReason`, async function () {
        const f = await loadFixture(mintedFixture);
        await expect((await burnMembership(f, { holder: f.extra1.address, reason })).tx)
          .to.be.revertedWithCustomError(f.membershipSBT, "InvalidBurnReason")
          .withArgs(reason);
      });
    }
  });

  describe("소각", function () {
    for (const [label, reason] of Object.entries(BurnReason)) {
      it(`${label} 소각: 이벤트, tokenOf == 0, hasValidMembership == false, 토큰 사라짐`, async function () {
        const f = await loadFixture(mintedFixture);
        const tx = (await burnMembership(f, { holder: f.extra1.address, reason }, f.auditor)).tx;
        await expect(tx)
          .to.emit(f.membershipSBT, "MembershipBurned")
          .withArgs(1n, f.extra1.address, TERM, reason, f.auditor.address);
        await gas("MembershipSBT.burnRelayed", tx);
        expect(await f.membershipSBT.tokenOf(f.extra1.address, TERM)).to.equal(0n);
        expect(await f.membershipSBT.hasValidMembership(f.extra1.address, TERM)).to.equal(false);
        expect(await f.membershipSBT.balanceOf(f.extra1.address)).to.equal(0n);
        await expect(f.membershipSBT.ownerOf(1n)).to.be.revertedWithCustomError(
          f.membershipSBT,
          "ERC721NonexistentToken",
        );
      });
    }

    it("소각 뒤 같은 학기 재발행은 새 tokenId 로 성공한다", async function () {
      const f = await loadFixture(mintedFixture);
      await (await burnMembership(f, { holder: f.extra1.address })).tx;
      await expect((await mintBatch(f, { recipients: [f.extra1.address] })).tx)
        .to.emit(f.membershipSBT, "MembershipMinted")
        .withArgs(2n, f.extra1.address, TERM, f.president.address);
      expect(await f.membershipSBT.tokenOf(f.extra1.address, TERM)).to.equal(2n);
    });

    it("같은 회원권 두 번째 소각은 NoMembership", async function () {
      const f = await loadFixture(mintedFixture);
      await (await burnMembership(f, { holder: f.extra1.address })).tx;
      await expect((await burnMembership(f, { holder: f.extra1.address })).tx).to.be.revertedWithCustomError(
        f.membershipSBT,
        "NoMembership",
      );
    });
  });

  describe("nonce·시한·서명", function () {
    it("서명자별 nonce 는 서로 독립이다", async function () {
      const f = await loadFixture(deployFixture);
      await (await mintBatch(f, { recipients: [f.extra1.address] }, f.president)).tx;
      expect(await f.membershipSBT.nonces(f.president.address)).to.equal(1n);
      expect(await f.membershipSBT.nonces(f.auditor.address)).to.equal(0n);
      await (await mintBatch(f, { recipients: [f.extra2.address] }, f.auditor)).tx; // 감사는 0 으로 성공
      expect(await f.membershipSBT.nonces(f.auditor.address)).to.equal(1n);
    });

    it("발행과 소각이 nonce 를 공유한다", async function () {
      const f = await loadFixture(mintedFixture); // 회장 nonce 1
      // 소각을 nonce 0 으로 서명하면 이미 발행에 쓴 값이다
      await expect((await burnMembership(f, { holder: f.extra1.address, nonce: 0n })).tx)
        .to.be.revertedWithCustomError(f.membershipSBT, "InvalidNonce")
        .withArgs(1n, 0n);
      await (await burnMembership(f, { holder: f.extra1.address })).tx; // nonce 1
      expect(await f.membershipSBT.nonces(f.president.address)).to.equal(2n);
    });

    it("같은 서명 재제출은 InvalidNonce", async function () {
      const f = await loadFixture(deployFixture);
      const { req, sig, tx } = await mintBatch(f, { recipients: [f.extra1.address] });
      await (await tx).wait();
      await expect(mintWithSig(f, req, sig))
        .to.be.revertedWithCustomError(f.membershipSBT, "InvalidNonce")
        .withArgs(1n, 0n);
    });

    it("같은 nonce 로 받아 둔 두 서명은 먼저 실행된 쪽만 성공한다 (발행 vs 소각 경합)", async function () {
      const f = await loadFixture(mintedFixture); // 회장 nonce 1
      const deadline = await deadlineIn();
      const mintReq = { recipients: [f.extra2.address], term: TERM, nonce: 1n, deadline };
      const burnReq = { holder: f.extra1.address, term: TERM, reason: BurnReason.REFUND, nonce: 1n, deadline };
      const mintSig = await signMintBatch(f.president, f.membershipSBT, mintReq);
      const burnSig = await signBurn(f.president, f.membershipSBT, burnReq);
      await (await burnWithSig(f, burnReq, burnSig)).wait();
      await expect(mintWithSig(f, mintReq, mintSig))
        .to.be.revertedWithCustomError(f.membershipSBT, "InvalidNonce")
        .withArgs(2n, 1n);
    });

    it("앞선 nonce 는 InvalidNonce", async function () {
      const f = await loadFixture(deployFixture);
      await expect((await mintBatch(f, { recipients: [f.extra1.address], nonce: 5n })).tx)
        .to.be.revertedWithCustomError(f.membershipSBT, "InvalidNonce")
        .withArgs(0n, 5n);
    });

    it("시한이 지난 서명은 SignatureExpired (발행·소각)", async function () {
      const f = await loadFixture(mintedFixture);
      const deadline = await deadlineIn(60);
      const mint = await signedMint(f, { recipients: [f.extra2.address], deadline });
      const burn = await signedBurn(f, { holder: f.extra1.address, deadline });
      await time.increaseTo(deadline + 1n);
      await expect(mintWithSig(f, mint.req, mint.sig))
        .to.be.revertedWithCustomError(f.membershipSBT, "SignatureExpired")
        .withArgs(deadline);
      await expect(burnWithSig(f, burn.req, burn.sig))
        .to.be.revertedWithCustomError(f.membershipSBT, "SignatureExpired")
        .withArgs(deadline);
    });

    it("깨진 서명 바이트는 InvalidSignature", async function () {
      const f = await loadFixture(mintedFixture);
      const mint = await signedMint(f, { recipients: [f.extra2.address] });
      const burn = await signedBurn(f, { holder: f.extra1.address });
      for (const bad of ["0x", "0x1234", "0x" + "00".repeat(65)]) {
        await expect(mintWithSig(f, mint.req, bad)).to.be.revertedWithCustomError(f.membershipSBT, "InvalidSignature");
        await expect(burnWithSig(f, burn.req, bad)).to.be.revertedWithCustomError(f.membershipSBT, "InvalidSignature");
      }
    });
  });

  describe("서명 변조", function () {
    // 값을 바꾸면 digest 가 달라져 다른 주소가 복구된다 → 그 주소는 롤이 없으므로 NotApprover.
    // 회장으로 복구됐다면 NotApprover 가 아니라 성공(또는 다른 검사 에러)이었을 것이다.
    async function expectTampered(f: Fixture, txPromise: Promise<any>) {
      await expect(txPromise).to.be.revertedWithCustomError(f.membershipSBT, "NotApprover");
    }

    it("수령자 순서·구성·term 을 바꾸면 회장 서명으로 인정되지 않는다", async function () {
      const f = await loadFixture(deployFixture);
      const [a, b, c] = wallets(3);
      const { req, sig } = await signedMint(f, { recipients: [a, b] });
      await expectTampered(f, mintWithSig(f, { ...req, recipients: [b, a] }, sig));
      await expectTampered(f, mintWithSig(f, { ...req, recipients: [a, b, c] }, sig));
      await expectTampered(f, mintWithSig(f, { ...req, recipients: [a] }, sig));
      await expectTampered(f, mintWithSig(f, { ...req, term: OTHER_TERM }, sig));
      expect(await f.membershipSBT.nonces(f.president.address)).to.equal(0n);
    });

    it("소각 대상·term·reason 을 바꾸면 회장 서명으로 인정되지 않는다", async function () {
      const f = await loadFixture(mintedFixture);
      const { req, sig } = await signedBurn(f, { holder: f.extra1.address, reason: BurnReason.REFUND });
      await expectTampered(f, burnWithSig(f, { ...req, reason: BurnReason.WITHDRAWAL }, sig));
      await expectTampered(f, burnWithSig(f, { ...req, holder: f.extra2.address }, sig));
      await expectTampered(f, burnWithSig(f, { ...req, term: OTHER_TERM }, sig));
    });

    it("다른 도메인(이름·컨트랙트 주소·chainId)으로 만든 서명은 인정되지 않는다", async function () {
      const f = await loadFixture(deployFixture);
      const { chainId } = await ethers.provider.getNetwork();
      const req = { recipients: [f.extra1.address], term: TERM, nonce: 0n, deadline: await deadlineIn() };
      const types = { MintBatchRequest: SBT_TYPES.MintBatchRequest as any };
      const domains = [
        { name: "BudgetToken", version: "1", chainId, verifyingContract: f.addresses.MembershipSBT },
        { name: "MembershipSBT", version: "2", chainId, verifyingContract: f.addresses.MembershipSBT },
        { name: "MembershipSBT", version: "1", chainId, verifyingContract: f.addresses.BudgetToken },
        { name: "MembershipSBT", version: "1", chainId: chainId + 1n, verifyingContract: f.addresses.MembershipSBT },
      ];
      for (const domain of domains) {
        const sig = await f.president.signTypedData(domain, types, req);
        await expectTampered(f, mintWithSig(f, req, sig));
      }
    });

    it("컨트랙트 digest 는 표준 EIP-712(address[] 포함) 계산과 같다", async function () {
      const f = await loadFixture(deployFixture);
      const [a, b] = wallets(2);
      const { req, sig } = await signedMint(f, { recipients: [a, b] });
      const { chainId } = await ethers.provider.getNetwork();
      const domain = { name: "MembershipSBT", version: "1", chainId, verifyingContract: f.addresses.MembershipSBT };
      expect(ethers.verifyTypedData(domain, { MintBatchRequest: SBT_TYPES.MintBatchRequest as any }, req, sig)).to.equal(
        f.president.address,
      );
      // 표준 계산으로 회장이 복구되는 서명을 컨트랙트도 회장으로 받는다
      await expect(mintWithSig(f, req, sig))
        .to.emit(f.membershipSBT, "MembershipMinted")
        .withArgs(1n, a, TERM, f.president.address);
    });
  });

  describe("전송 불가 (Soulbound)", function () {
    it("보유자 본인의 transferFrom·safeTransferFrom 두 형태 모두 Soulbound", async function () {
      const f = await loadFixture(mintedFixture);
      const sbt = f.membershipSBT.connect(f.extra1);
      await expect(sbt.transferFrom(f.extra1.address, f.extra2.address, 1n)).to.be.revertedWithCustomError(
        sbt,
        "Soulbound",
      );
      await expect(
        sbt["safeTransferFrom(address,address,uint256)"](f.extra1.address, f.extra2.address, 1n),
      ).to.be.revertedWithCustomError(sbt, "Soulbound");
      await expect(
        sbt["safeTransferFrom(address,address,uint256,bytes)"](f.extra1.address, f.extra2.address, 1n, "0x"),
      ).to.be.revertedWithCustomError(sbt, "Soulbound");
      expect(await f.membershipSBT.ownerOf(1n)).to.equal(f.extra1.address);
    });

    it("임원·릴레이어가 보내도 Soulbound", async function () {
      const f = await loadFixture(mintedFixture);
      for (const who of [f.president, f.auditor, f.relayer]) {
        await expect(
          f.membershipSBT.connect(who).transferFrom(f.extra1.address, who.address, 1n),
        ).to.be.revertedWithCustomError(f.membershipSBT, "Soulbound");
      }
    });

    it("approve·setApprovalForAll 은 Soulbound", async function () {
      const f = await loadFixture(mintedFixture);
      const sbt = f.membershipSBT.connect(f.extra1);
      await expect(sbt.approve(f.extra2.address, 1n)).to.be.revertedWithCustomError(sbt, "Soulbound");
      await expect(sbt.setApprovalForAll(f.extra2.address, true)).to.be.revertedWithCustomError(sbt, "Soulbound");
      expect(await f.membershipSBT.getApproved(1n)).to.equal(ZERO_ADDR);
      expect(await f.membershipSBT.isApprovedForAll(f.extra1.address, f.extra2.address)).to.equal(false);
    });
  });

  describe("ABI", function () {
    it("상태를 바꾸는 함수는 발행·소각과 (막혀 있는) ERC721 전송·승인뿐이다", async function () {
      const f = await loadFixture(deployFixture);
      const mutating = f.membershipSBT.interface.fragments
        .filter((x: any) => x.type === "function" && x.stateMutability !== "view" && x.stateMutability !== "pure")
        .map((x: any) => x.format("sighash"))
        .sort();
      expect(mutating).to.deep.equal(
        [
          "burnRelayed((address,uint256,uint8,uint256,uint256),bytes)",
          "mintBatchRelayed((address[],uint256,uint256,uint256),bytes)",
          "safeTransferFrom(address,address,uint256)",
          "safeTransferFrom(address,address,uint256,bytes)",
          "transferFrom(address,address,uint256)",
        ].sort(),
      );
    });

    it("요청 구조체에는 지갑 주소·학기·서명 필드만 있다 (학번 등 식별정보 없음)", async function () {
      const f = await loadFixture(deployFixture);
      const fields = (sig: string) =>
        f.membershipSBT.interface.getFunction(sig)!.inputs[0].components!.map((c: any) => c.name);
      expect(fields("mintBatchRelayed")).to.deep.equal(["recipients", "term", "nonce", "deadline"]);
      expect(fields("burnRelayed")).to.deep.equal(["holder", "term", "reason", "nonce", "deadline"]);
      for (const ev of ["MembershipMinted", "MembershipSkipped", "MembershipBurned"]) {
        const names = f.membershipSBT.interface.getEvent(ev)!.inputs.map((i: any) => i.name);
        expect(names.every((n: string) => ["tokenId", "to", "from", "term", "reason", "actor"].includes(n)), ev).to.equal(
          true,
        );
      }
    });
  });
});
