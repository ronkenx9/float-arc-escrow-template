# `float-arc-escrow-template`

**A 2-party escrow on Arc that earns USYC yield on locked capital.**
Fork this repo, change the dispute logic, ship.

```solidity
constructor(address _beneficiary, address _arbiter, uint256 _amount, uint256 _timeoutSeconds) {
    USDC.safeTransferFrom(msg.sender, address(this), _amount);

    // ───────────────── FLOAT ─────────────────
    uint256 parkAmount = (_amount * 9_500) / 10_000;   // 95% parked
    USDC.forceApprove(address(FLOAT_VAULT), parkAmount);
    FLOAT_VAULT.park(parkAmount);
    // ─────────────────────────────────────────

    // … set depositor, beneficiary, arbiter, timeoutAt …
}
```

Funds enter on construction, park immediately, sit earning yield until
`release()` or `refund()` is called. Two FLOAT call sites total —
park-on-create, recall-on-payout.

---

## Why this exists

Every escrow holds idle USDC by definition. Days, weeks, sometimes months
of capital sitting waiting for a counterparty to sign off, a service to
be delivered, a milestone to hit, or a dispute window to close.

This template wraps any 2-party escrow in FLOAT yield routing. The
integration is so small you can drop it into your existing escrow contract
in 5 lines.

Same idea as the [prediction market template](https://github.com/ronkenx9/float-arc-template),
adapted for a counterparty-settled flow:

| | Prediction market | Escrow |
|---|---|---|
| Funds in | `bet()` | constructor |
| Funds locked until | resolution time | release/refund/arbiter |
| Outcome resolver | owner (or oracle) | depositor/beneficiary/arbiter |
| Distribution | parimutuel | single recipient |

---

## Roles

| Role | Set by | Powers |
|---|---|---|
| **Depositor** | constructor (`msg.sender`) | Can `release()` to pay beneficiary anytime. Can `refund()` themselves after `timeoutAt`. |
| **Beneficiary** | constructor arg | Can `refund()` to give back (voluntary cancellation). |
| **Arbiter** | constructor arg, can be `address(0)` | Only active in `DISPUTED` state. Can `release()` or `refund()` to break the tie. |

Either party can call `dispute()` to freeze the escrow. Once disputed,
only the arbiter can move funds. If no arbiter was set, `dispute()`
reverts — the contract is depositor-resolution or timeout only.

---

## Risk model

USYC is a NAV-based product backed by short-dated US Treasuries (managed by
Hashnote). "Depeg" risk is closer to a money market fund moving 0.05% in a
stress event than to UST/USDC-style breakage. On Arc the recall is a single
onchain instruction — no AMM slippage, no cross-chain bridge risk.

Residual risk is still non-zero. This contract defends against it with
**four layers** of protection:

### Layer 1 — Liquid reserve buffer

```solidity
uint256 public constant RESERVE_BPS = 500;   // 5%
```

95% goes into FLOAT, 5% stays liquid in the contract. Yield from the parked
95% has to underperform by more than the buffer to threaten principal.

### Layer 2 — Recall-first, pay-second (fault-tolerant)

`release()` and `refund()` recall everything from FLOAT *before* paying out.
<5s on Arc. The vault call is wrapped in `try/catch`, so a transient vault
failure can't lock the contract — payout still happens with whatever's
liquid.

### Layer 3 — Shortfall surfaced via event

If the recalled amount is less than the original deposit, the `Released`
or `Refunded` event includes `shortfall: true`. The recipient gets all
recovered funds (less than the original amount). No silent loss.

### Layer 4 — Timeout escape

If the beneficiary disappears, the depositor can call `refund()` after
`timeoutAt` and recover their funds. No requirement for the beneficiary
to be online.

> ⚠ **Caveat:** the timeout escape only applies in `ACTIVE` state. Once a
> dispute is filed, only the arbiter can move funds — a non-responsive
> arbiter can permanently lock the escrow. If you don't fully trust your
> arbiter, add a dispute-timeout: after N days in DISPUTED state, allow
> the depositor to force-refund. ~20 lines to add; left out of the
> template to keep the core flow scannable.

---

## Three things to change after forking

1. **Beneficiary / arbiter logic** — currently single beneficiary, single
   arbiter. Replace with multi-sig, DAO vote, or an oracle of your choice.

2. **Release/refund conditions** — currently depositor-approves or
   timeout-refunds. Add milestone-based partial releases, percentage splits,
   oracle-triggered settlement, etc.

3. **Yield policy** — currently the recipient gets the yield (beneficiary
   on release, depositor on refund). To always return yield to the
   depositor (the capital provider), modify `_recallAndTransfer()` to split
   principal from yield.

Optional fourth: adjust `RESERVE_BPS` to your risk tolerance.

---

## Deployment

```bash
cp .env.example .env
# fill in:
#   PRIVATE_KEY=
#   ARC_TESTNET_RPC=    (default: https://rpc.testnet.arc.network)

npm install
npx hardhat compile

# Edit scripts/deploy.ts → set BENEFICIARY, ARBITER, AMOUNT_USDC, TIMEOUT_HOURS
npx hardhat run scripts/deploy.ts --network arcTestnet
```

The script computes the future escrow address (via `CREATE` nonce
prediction), approves USDC to that address, then deploys. This lets the
constructor pull USDC in the same atomic deploy transaction.

The deployer wallet needs to hold ≥ AMOUNT_USDC of USDC on Arc Testnet.
Grab some from [the Circle faucet](https://faucet.circle.com).

---

## Demo (end-to-end)

```bash
npx hardhat run scripts/demo.ts --network arcTestnet
```

This script:

1. Deploys an escrow with a fresh beneficiary, 30-second timeout, 1 USDC
2. Shows the parked / liquid split (~95% in FLOAT, ~5% reserve)
3. Calls `release()` from the depositor
4. Verifies the beneficiary received the funds

Watch the events — you'll see `EscrowCreated`, `Parked`, and `Released`
fire as USDC flows through FLOAT.

---

## Contracts

| Contract | Address (Arc Testnet) |
|---|---|
| USDC | `0x3600000000000000000000000000000000000000` |
| FloatVault | `0xfAe6a9D5b0835ca7e9B090eCe0f57C14899BeDA6` |

Your `Escrow` contract address gets printed after `deploy.ts` runs.

---

## What this is *not*

- Not a multi-escrow vault — one contract = one escrow. For high-volume
  use cases, fork to a single contract with `mapping(uint256 => Escrow)`.
  The FLOAT integration is identical.
- Not production-grade by itself — needs proper arbitration (oracle, DAO,
  or trusted third party), KYC if your jurisdiction requires it, and
  probably a frontend.
- Not the only way to integrate FLOAT — agent-side integration (off-chain
  via [`@floatrouter/sdk`](https://github.com/ronkenx9/floatrouter-sdk))
  is also supported.

---

## License

MIT
