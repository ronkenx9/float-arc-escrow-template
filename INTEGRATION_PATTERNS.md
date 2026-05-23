# FLOAT integration patterns

Every contract-side FLOAT integration looks the same. There's only one
shape:

```
1. Funds enter contract     → park()        (in the same tx as the deposit)
2. Funds sit for a window   → earn USYC     (no contract action needed)
3. Trigger event fires      → withdraw()    (recall before distributing)
4. Funds leave contract     → safeTransfer  (to whoever the recipient is)
```

This doc shows how to bend that pattern to fit different use cases. Each
section gives you the diff against an existing template — what to add,
what to replace.

The two reference repos:

| Repo | Pattern |
|---|---|
| [`float-arc-template`](https://github.com/ronkenx9/float-arc-template) | Many depositors, one outcome, parimutuel payout (prediction market) |
| [`float-arc-escrow-template`](https://github.com/ronkenx9/float-arc-escrow-template) | One depositor, one beneficiary, single payout (2-party escrow) |

---

## Pattern A — single-party deposit, single recipient

> Use cases: escrow, milestone payments, B2B settlement, conditional payments

Already covered by [`float-arc-escrow-template`](https://github.com/ronkenx9/float-arc-escrow-template).
Fork it as-is. Customize:

- Replace `dispute()` with your trigger logic (oracle, multisig, time-lock)
- Replace `release()` / `refund()` with milestone-based partial unlocks if you want
- Yield policy in `_recallAndTransfer()` if recipient shouldn't get yield

---

## Pattern B — pooled deposits, proportional payout

> Use cases: prediction markets, lotteries, parimutuel betting

Already covered by [`float-arc-template`](https://github.com/ronkenx9/float-arc-template).
Fork it as-is. Customize:

- Replace `bet(bool, amount)` with whatever your deposit semantics are
- Replace `resolve(Outcome)` with oracle/DAO-driven resolution
- Replace the parimutuel payout math in `claim()` with LMSR or your own

---

## Pattern C — DAO treasury idle-yield module

> Use case: a DAO holds USDC reserves between governance proposals.
> Most idle USDC should earn; some should stay liquid for instant grants.

**Diff from the escrow template:**

```solidity
// Replace single-depositor with treasury-controlled deposits
function depositFromTreasury(uint256 amount) external onlyTreasury {
    USDC.safeTransferFrom(msg.sender, address(this), amount);

    // ───────────────── FLOAT ─────────────────
    uint256 parkAmount = (amount * (BPS_DENOM - RESERVE_BPS)) / BPS_DENOM;
    USDC.forceApprove(address(FLOAT_VAULT), parkAmount);
    FLOAT_VAULT.park(parkAmount);
    // ─────────────────────────────────────────
}

// Replace release()/refund() with a single proposal-triggered disburse
function disburseToProposal(address recipient, uint256 amount)
    external
    onlyExecutor   // your governance executor module
{
    // ───────────────── FLOAT ─────────────────
    // Recall enough to cover the disbursement + safety margin
    uint256 needed = amount;
    uint256 liquid = USDC.balanceOf(address(this));
    if (liquid < needed) {
        uint256 deficit = needed - liquid;
        FLOAT_VAULT.withdraw(deficit);
    }
    // ─────────────────────────────────────────

    USDC.safeTransfer(recipient, amount);
}
```

**Key idea:** for a treasury you don't recall everything at once — you
recall *only what's needed for this disbursement*, leaving the rest
earning yield. The escrow template recalls 100%; the treasury pattern
recalls just the deficit.

`RESERVE_BPS` becomes more important here — it's the working-capital
buffer that lets small disbursements happen without a FLOAT round-trip.

---

## Pattern D — auction escrow / marketplace bids

> Use case: bidders lock USDC during an auction; winner pays, losers refunded.

**Diff from the prediction-market template:**

```solidity
// Replace bet(bool, amount) with bid(amount)
mapping(address => uint256) public bids;
address public highestBidder;
uint256 public highestBid;

function bid(uint256 amount) external {
    require(amount > highestBid, "outbid");
    require(block.timestamp < auctionEnd, "ended");

    USDC.safeTransferFrom(msg.sender, address(this), amount);

    // ───────────────── FLOAT ─────────────────
    uint256 parkAmount = (amount * (BPS_DENOM - RESERVE_BPS)) / BPS_DENOM;
    if (parkAmount > 0) {
        USDC.forceApprove(address(FLOAT_VAULT), parkAmount);
        FLOAT_VAULT.park(parkAmount);
    }
    // ─────────────────────────────────────────

    bids[msg.sender] += amount;
    if (bids[msg.sender] > highestBid) {
        highestBidder = msg.sender;
        highestBid = bids[msg.sender];
    }
}

// On auction end: settle to seller, allow losers to claim refunds
function settle() external {
    require(block.timestamp >= auctionEnd, "still open");

    // ───────────────── FLOAT ─────────────────
    uint256 parked = FLOAT_VAULT.deposits(address(this));
    if (parked > 0) FLOAT_VAULT.withdraw(parked);
    // ─────────────────────────────────────────

    USDC.safeTransfer(seller, highestBid);
    // (losers call claimRefund() to retrieve bids[msg.sender] — bounded by remaining balance)
}
```

**Key idea:** marketplace bids are just deposits with a "winner takes seller's
cut, losers get refunds" resolution rule. Same FLOAT integration as a market.

---

## Pattern E — payroll vault / scheduled disbursement

> Use case: employer funds the contract upfront; contract pays employees on schedule.

**Diff from the escrow template:**

```solidity
// Replace 2-party escrow with N-recipient schedule
struct Payee {
    address wallet;
    uint256 monthlyAmount;
    uint256 nextPayoutAt;
}
mapping(uint256 => Payee) public payees;

constructor(uint256 totalFundAmount) {
    USDC.safeTransferFrom(msg.sender, address(this), totalFundAmount);
    // ───────────────── FLOAT ─────────────────
    uint256 parkAmount = (totalFundAmount * (BPS_DENOM - RESERVE_BPS)) / BPS_DENOM;
    USDC.forceApprove(address(FLOAT_VAULT), parkAmount);
    FLOAT_VAULT.park(parkAmount);
    // ─────────────────────────────────────────
}

function payout(uint256 payeeId) external {
    Payee storage p = payees[payeeId];
    require(block.timestamp >= p.nextPayoutAt, "too early");

    // ───────────────── FLOAT ─────────────────
    // Recall just enough for this payment (same as treasury pattern)
    uint256 liquid = USDC.balanceOf(address(this));
    if (liquid < p.monthlyAmount) {
        FLOAT_VAULT.withdraw(p.monthlyAmount - liquid);
    }
    // ─────────────────────────────────────────

    USDC.safeTransfer(p.wallet, p.monthlyAmount);
    p.nextPayoutAt += 30 days;
}
```

**Key idea:** front-load the funding (one big deposit), drip out the payouts.
Yield accrues on the un-disbursed balance — over a year, ~5% yield on the
average outstanding balance is meaningful.

---

## Pattern F — off-chain agent (not a contract)

> Use cases: trading bots, AI agents, automated payment dispatchers, anything
> that holds USDC in a Circle Agent Wallet (not a Solidity contract).

**Don't use this repo.** Use the SDK:

```bash
npm install @floatrouter/sdk
```

```ts
import { wrapAgent } from '@floatrouter/sdk';

const flo = wrapAgent(myAgent, { strategy: 'balanced', vault: 'USYC' });
const safePay = flo.wrapPayment(executePayment);
// FLOAT auto-recalls from USYC if your wallet is short, then pays.
```

The SDK is the right tool when the holder of USDC is a wallet (not a
contract). It wraps any Circle Agent Wallet in five lines.

---

## The universal pattern

If you remember nothing else from this doc, remember this:

```solidity
// On deposit
USDC.forceApprove(address(FLOAT_VAULT), parkAmount);
FLOAT_VAULT.park(parkAmount);

// On payout
uint256 parked = FLOAT_VAULT.deposits(address(this));
FLOAT_VAULT.withdraw(parked);   // (or partial — withdraw(needed - liquid))
USDC.safeTransfer(recipient, amount);
```

That's it. Six lines. Everything else in these templates is your business
logic. The FLOAT integration is the smallest layer in the stack.

---

## Risk model (applies to all patterns)

1. **Liquid reserve** — never park 100% of the pool. Default 5%. Acts as a
   buffer against any USYC NAV underperformance and lets small operations
   complete without a FLOAT round-trip.

2. **Recall before distribute** — never assume parked funds are instantly
   available. Always call `FLOAT_VAULT.withdraw()` before transferring out.

3. **Shortfall handling** — wrap `withdraw()` in `try/catch` and degrade
   gracefully if it fails. Pay out whatever's recoverable rather than
   reverting the entire transaction.

4. **Single source of truth** — use `FLOAT_VAULT.deposits(address(this))`
   for the parked amount, not a contract-local cache. Vault state is
   the ground truth (avoid ESTIMATION_ERROR).

5. **Reentrancy** — add `nonReentrant` to anything that touches USDC and
   external contracts in the same flow.

These five rules cover ~95% of the integration gotchas.

---

## Need help?

- Open an issue on [`float-arc-template`](https://github.com/ronkenx9/float-arc-template/issues)
- DM [@floatrouter](https://x.com/floatrouter)
- The SDK source is at [`floatrouter-sdk`](https://github.com/ronkenx9/floatrouter-sdk)
