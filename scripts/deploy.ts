/**
 * Deploys a single Escrow contract to Arc Testnet.
 *
 * Edit the constants below before running.
 *
 * USDC flow:
 *   1. We compute the FUTURE escrow address using CREATE nonce prediction
 *   2. Depositor approves USDC to that predicted address
 *   3. Constructor runs safeTransferFrom in the same atomic deploy tx
 *
 * Run:
 *   npx hardhat run scripts/deploy.ts --network arcTestnet
 */
import { ethers } from "hardhat";

const BENEFICIARY      = "0x0000000000000000000000000000000000000001"; // ← change me
const ARBITER          = "0x0000000000000000000000000000000000000000"; // address(0) = no arbiter
const AMOUNT_USDC      = 10;        // USDC amount to escrow (will be * 1e6)
const TIMEOUT_HOURS    = 168;       // 7 days — depositor can auto-refund after this

const USDC_ADDRESS = "0x3600000000000000000000000000000000000000";

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
];

async function main() {
  const [deployer] = await ethers.getSigners();
  const deployerAddr = await deployer.getAddress();
  console.log(`Deployer: ${deployerAddr}`);
  console.log(`Network:  ${(await ethers.provider.getNetwork()).chainId}\n`);

  const amount = BigInt(AMOUNT_USDC) * 1_000_000n;
  const timeoutSeconds = BigInt(TIMEOUT_HOURS * 3600);

  /* ─── Pre-flight checks ─── */
  const usdc = new ethers.Contract(USDC_ADDRESS, ERC20_ABI, deployer);
  const balance = await usdc.balanceOf(deployerAddr);
  if (balance < amount) {
    console.error(`Insufficient USDC: have ${balance}, need ${amount}.`);
    console.error(`Get testnet USDC from https://faucet.circle.com`);
    process.exitCode = 1;
    return;
  }

  /* ─── Predict the escrow address and approve USDC to it ─── */
  // The escrow's constructor calls `USDC.safeTransferFrom(depositor, escrow, amount)`.
  // The depositor needs to approve the *escrow* address (not their own).
  // We compute it via CREATE nonce prediction.
  //
  // Nonce math: approve() consumes nonce N, then deploy uses nonce N+1.
  // The contract will be created at address(deployer, N+1).
  const nonce = await ethers.provider.getTransactionCount(deployerAddr);
  const predictedAddr = ethers.getCreateAddress({ from: deployerAddr, nonce: nonce + 1 });
  console.log(`Predicted escrow address: ${predictedAddr}\n`);

  console.log(`Approving ${AMOUNT_USDC} USDC to predicted escrow address…`);
  await (await usdc.approve(predictedAddr, amount)).wait();

  /* ─── Deploy ─── */
  const Factory = await ethers.getContractFactory("Escrow");
  const escrow  = await Factory.deploy(
    BENEFICIARY,
    ARBITER,
    amount,
    timeoutSeconds,
  );
  await escrow.waitForDeployment();
  const address = await escrow.getAddress();

  console.log("");
  console.log(`✅ Escrow deployed at: ${address}`);
  console.log(`   Depositor:    ${deployerAddr}`);
  console.log(`   Beneficiary:  ${BENEFICIARY}`);
  console.log(`   Arbiter:      ${ARBITER === ethers.ZeroAddress ? "(none)" : ARBITER}`);
  console.log(`   Amount:       ${AMOUNT_USDC} USDC`);
  console.log(`   Auto-refund:  ${new Date((Date.now() / 1000 + TIMEOUT_HOURS * 3600) * 1000).toISOString()}`);
  console.log(`   Reserve:      5% (RESERVE_BPS = 500)`);
  console.log("");
  console.log("Next steps:");
  console.log(`  · release  — depositor calls release() to pay beneficiary`);
  console.log(`  · refund   — beneficiary calls refund() to cancel, or`);
  console.log(`               depositor calls refund() after the timeout`);
  console.log(`  · dispute  — either party calls dispute() (requires arbiter set)`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
