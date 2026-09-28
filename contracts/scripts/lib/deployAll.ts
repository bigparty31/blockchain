/**
 * 컨트랙트 4단계 배포 순서를 한 곳에 둔다. 배포 스크립트와 테스트 픽스처가 같은 함수를 쓴다.
 *
 *   RoleManager(president, treasurer, auditor)
 *   → BudgetToken(roleManager)
 *   → AccountingLedger(roleManager, budgetToken)
 *   → BudgetToken.setLedger(ledger)   // 배포자가 1회 호출, 이후 잠김
 *
 * 세 임원은 생성자 인자로 들어가므로 별도 롤 부여 단계가 없다.
 * 배포자는 setLedger 를 부른 뒤 어떤 권한도 남지 않는다 (docs/CONTRACTS.md "생성자·배포 순서").
 */

export interface Officers {
  president: string;
  treasurer: string;
  auditor: string;
}

export interface Deployment {
  roleManager: any;
  budgetToken: any;
  ledger: any;
  addresses: { RoleManager: string; BudgetToken: string; AccountingLedger: string };
  blocks: { RoleManager: number; BudgetToken: number; AccountingLedger: number; setLedger: number };
}

async function deployedBlock(contract: any): Promise<number> {
  const tx = contract.deploymentTransaction();
  const receipt = await tx.wait();
  return receipt.blockNumber;
}

export async function deployAll(ethers: any, officers: Officers, deployer?: any): Promise<Deployment> {
  const signer = deployer ?? (await ethers.getSigners())[0];

  const roleManager = await ethers.deployContract(
    "RoleManager",
    [officers.president, officers.treasurer, officers.auditor],
    signer,
  );
  await roleManager.waitForDeployment();

  const budgetToken = await ethers.deployContract("BudgetToken", [await roleManager.getAddress()], signer);
  await budgetToken.waitForDeployment();

  const ledger = await ethers.deployContract(
    "AccountingLedger",
    [await roleManager.getAddress(), await budgetToken.getAddress()],
    signer,
  );
  await ledger.waitForDeployment();

  const setTx = await budgetToken.connect(signer).setLedger(await ledger.getAddress());
  const setReceipt = await setTx.wait();

  return {
    roleManager,
    budgetToken,
    ledger,
    addresses: {
      RoleManager: await roleManager.getAddress(),
      BudgetToken: await budgetToken.getAddress(),
      AccountingLedger: await ledger.getAddress(),
    },
    blocks: {
      RoleManager: await deployedBlock(roleManager),
      BudgetToken: await deployedBlock(budgetToken),
      AccountingLedger: await deployedBlock(ledger),
      setLedger: setReceipt.blockNumber,
    },
  };
}
