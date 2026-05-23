/**
 * End-to-end demo flow on Arc Testnet:
 *   1. Deploy a 30-second-timeout escrow
 *   2. Show the parked / liquid split (FLOAT holds ~95%)
 *   3. Wait 5s, then release to beneficiary
 *   4. Verify balances
 *
 * Requires the deployer wallet to hold at least 1 USDC on Arc Testnet.
 * Uses a fresh signer as the beneficiary (you'll see funds move to that
 * address; if you want to recover, change BENEFICIARY to your own address).
 *
 * Run:
 *   npx hardhat run scripts/demo.ts --network arcTestnet
 */
import { ethers } from "hardhat";

const USDC_ADDRESS  = "0x3600000000000000000000000000000000000000";
const ONE_USDC      = 1_000_000n;
const AMOUNT        = ONE_USDC;          // escrow 1 USDC
const TIMEOUT_SECS  = 30n;

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
];

async function main() {
  const [depositor] = await ethers.getSigners();
  const depositorAddr = await depositor.getAddress();

  // Generate a fresh beneficiary address (no private key needed for demo —
  // we won't sign txs from it, just observe its balance).
  const beneficiary = ethers.Wallet.createRandom().address;

  console.log(`Depositor:   ${depositorAddr}`);
  console.log(`Beneficiary: ${beneficiary}\n`);

  /* ─── 1. Pre-flight USDC balance ─── */
  const usdc = new ethers.Contract(USDC_ADDRESS, ERC20_ABI, depositor);
  const balance = await usdc.balanceOf(depositorAddr);
  console.log(`USDC balance: ${formatUsdc(balance)} USDC`);
  if (balance < AMOUNT) {
    console.error(`Need at least ${formatUsdc(AMOUNT)} USDC. Get some from https://faucet.circle.com\n`);
    process.exitCode = 1;
    return;
  }

  /* ─── 2. Compute the predicted escrow address and approve ─── */
  // approve() will consume nonce N, deploy will then use nonce N+1.
  const nonce = await ethers.provider.getTransactionCount(depositorAddr);
  const predictedAddr = ethers.getCreateAddress({ from: depositorAddr, nonce: nonce + 1 });
  console.log(`Predicted escrow address: ${predictedAddr}\n`);

  console.log(`Approving ${formatUsdc(AMOUNT)} USDC to predicted escrow…`);
  await (await usdc.approve(predictedAddr, AMOUNT)).wait();

  /* ─── 3. Deploy the escrow ─── */
  console.log("Deploying escrow…");
  const Factory = await ethers.getContractFactory("Escrow");
  const escrow  = await Factory.deploy(
    beneficiary,
    ethers.ZeroAddress,  // no arbiter
    AMOUNT,
    TIMEOUT_SECS,
  );
  await escrow.waitForDeployment();
  const escrowAddr = await escrow.getAddress();
  console.log(`✅ Escrow deployed: ${escrowAddr}\n`);

  /* ─── 4. Show the parked / liquid split ─── */
  const [liquid, parked] = await escrow.totalAssets();
  console.log("Escrow holdings after creation:");
  console.log(`  Liquid in contract: ${formatUsdc(liquid)} USDC  (5% reserve)`);
  console.log(`  Parked in FLOAT:    ${formatUsdc(parked)} USDC  (95% earning USYC yield)\n`);

  /* ─── 5. Brief delay (let FLOAT settle) then release ─── */
  await sleep(5_000);

  console.log("Depositor calls release() — paying beneficiary…");
  const releaseTx = await escrow.release();
  const receipt = await releaseTx.wait();

  const releasedEvent = receipt?.logs
    .map((log) => {
      try {
        return escrow.interface.parseLog({
          topics: Array.from(log.topics),
          data: log.data,
        });
      } catch { return null; }
    })
    .find((parsed) => parsed?.name === "Released");

  if (releasedEvent) {
    const paid     = releasedEvent.args.amount as bigint;
    const shortfall = releasedEvent.args.shortfall as boolean;
    console.log(`  → paid ${formatUsdc(paid)} USDC to beneficiary`);
    if (shortfall) console.log(`  ⚠️  SHORTFALL — recipient received less than the original ${formatUsdc(AMOUNT)} USDC`);
  }

  /* ─── 6. Verify final state ─── */
  const beneficiaryBalance = await usdc.balanceOf(beneficiary);
  const escrowFinal = await usdc.balanceOf(escrowAddr);
  const stateNum = await escrow.state();
  const stateNames = ["ACTIVE", "RELEASED", "REFUNDED", "DISPUTED"];

  console.log("\nFinal state:");
  console.log(`  Escrow state:        ${stateNames[Number(stateNum)]}`);
  console.log(`  Beneficiary balance: ${formatUsdc(beneficiaryBalance)} USDC`);
  console.log(`  Escrow leftover:     ${formatUsdc(escrowFinal)} USDC (should be 0)`);
}

function formatUsdc(amount: bigint): string {
  return (Number(amount) / 1_000_000).toFixed(6);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
