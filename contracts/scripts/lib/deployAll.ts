/**
 * 컨트랙트 5단계 배포 순서를 한 곳에 둔다. 배포 스크립트와 테스트 픽스처가 같은 함수를 쓴다.
 *
 *   RoleManager(president, treasurer, auditor1, auditor2)
 *   → BudgetToken(roleManager)
 *   → AccountingLedger(roleManager, budgetToken)
 *   → BudgetToken.setLedger(ledger)   // 배포자가 1회 호출, 이후 잠김
 *   → MembershipSBT(roleManager)
 *   → ObjectionRegistry(roleManager, ledger, membershipSBT, relayer)
 *
 * MembershipSBT·ObjectionRegistry 를 뒤에 두는 이유: 배포 주소는 배포자 nonce 로 정해진다. 앞의 컨트랙트와 setLedger 의
 * 순서를 그대로 두어야 그 주소와 EIP-712 도메인(앱·서버 벡터에 박힌 값)이 바뀌지 않는다.
 * ObjectionRegistry 는 PRD v0.17 에 추가됐다. 맨 뒤라 앞의 네 주소는 이전 배포와 같다.
 *
 * relayer 는 ObjectionRegistry.raise 를 부를 수 있는 유일한 주소다 (롤은 없다).
 *
 * 네 임원(회장·총무·감사 2명)은 생성자 인자로 들어가므로 별도 롤 부여 단계가 없다.
 * 배포자는 setLedger 를 부른 뒤 어떤 권한도 남지 않는다 (docs/CONTRACTS.md "생성자·배포 순서").
 *
 * ledgerContract 로 원장 자리에 다른 컨트랙트(테스트의 MockLedger)를 넣을 수 있다. 생성자 인자는 같다.
 */

export interface Officers {
  president: string;
  treasurer: string;
  auditor1: string;
  auditor2: string;
}

export interface DeployOptions {
  ledgerContract?: "AccountingLedger" | "MockLedger";
}

export interface Deployment {
  roleManager: any;
  budgetToken: any;
  ledger: any;
  membershipSBT: any;
  objectionRegistry: any;
  addresses: {
    RoleManager: string;
    BudgetToken: string;
    AccountingLedger: string;
    MembershipSBT: string;
    ObjectionRegistry: string;
  };
  blocks: {
    RoleManager: number;
    BudgetToken: number;
    AccountingLedger: number;
    setLedger: number;
    MembershipSBT: number;
    ObjectionRegistry: number;
  };
}

async function deployedBlock(contract: any): Promise<number> {
  const tx = contract.deploymentTransaction();
  const receipt = await tx.wait();
  return receipt.blockNumber;
}

export async function deployAll(
  ethers: any,
  officers: Officers,
  relayer: string,
  deployer?: any,
  opts: DeployOptions = {},
): Promise<Deployment> {
  const signer = deployer ?? (await ethers.getSigners())[0];
  const ledgerContract = opts.ledgerContract ?? "AccountingLedger";

  const roleManager = await ethers.deployContract(
    "RoleManager",
    [officers.president, officers.treasurer, officers.auditor1, officers.auditor2],
    signer,
  );
  await roleManager.waitForDeployment();

  const budgetToken = await ethers.deployContract("BudgetToken", [await roleManager.getAddress()], signer);
  await budgetToken.waitForDeployment();

  const ledger = await ethers.deployContract(
    ledgerContract,
    [await roleManager.getAddress(), await budgetToken.getAddress()],
    signer,
  );
  await ledger.waitForDeployment();

  const setTx = await budgetToken.connect(signer).setLedger(await ledger.getAddress());
  const setReceipt = await setTx.wait();

  const membershipSBT = await ethers.deployContract("MembershipSBT", [await roleManager.getAddress()], signer);
  await membershipSBT.waitForDeployment();

  const objectionRegistry = await ethers.deployContract(
    "ObjectionRegistry",
    [await roleManager.getAddress(), await ledger.getAddress(), await membershipSBT.getAddress(), relayer],
    signer,
  );
  await objectionRegistry.waitForDeployment();

  return {
    roleManager,
    budgetToken,
    ledger,
    membershipSBT,
    objectionRegistry,
    addresses: {
      RoleManager: await roleManager.getAddress(),
      BudgetToken: await budgetToken.getAddress(),
      AccountingLedger: await ledger.getAddress(),
      MembershipSBT: await membershipSBT.getAddress(),
      ObjectionRegistry: await objectionRegistry.getAddress(),
    },
    blocks: {
      RoleManager: await deployedBlock(roleManager),
      BudgetToken: await deployedBlock(budgetToken),
      AccountingLedger: await deployedBlock(ledger),
      setLedger: setReceipt.blockNumber,
      MembershipSBT: await deployedBlock(membershipSBT),
      ObjectionRegistry: await deployedBlock(objectionRegistry),
    },
  };
}
