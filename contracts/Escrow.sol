// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IFloatVault.sol";

/// @title  Escrow — Arc-native 2-party escrow with FLOAT yield routing
/// @notice Idle USDC in escrow earns USYC yield until released or refunded.
///         Fork this contract, change the dispute logic, ship.
///
///         FLOAT integration is exactly TWO call sites, both marked `── FLOAT ──`:
///           1. constructor()         → park (100% - reserve) of the deposit
///           2. _recallAndTransfer()  → recall everything before paying out
///                                      (called by release() and refund())
///
/// @dev Risk model
///   ────────────
///   Same four-layer defense as the prediction market template:
///   1. RESERVE_BPS — fraction of every deposit NEVER parked (5% default)
///   2. recall before payout — single onchain instruction on Arc
///   3. shortfall handling — recipient gets whatever survives, no winner-vs-loser
///      asymmetry possible since escrow has a single recipient per outcome
///   4. try/catch around vault calls — transient vault failure can't lock the
///      contract; payout still happens with whatever's liquid
///
/// @dev Yield policy
///   In this template, yield (any liquid > original amount) flows to whoever
///   receives the payout — beneficiary on release, depositor on refund. If you
///   want yield to always return to the depositor (the capital provider),
///   modify `_recallAndTransfer()` to split principal from yield.
contract Escrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ──────────────────────────────────────────────────────────────
       FLOAT integration — Arc Testnet addresses
       ────────────────────────────────────────────────────────────── */

    IERC20 public constant USDC =
        IERC20(0x3600000000000000000000000000000000000000);

    IFloatVault public constant FLOAT_VAULT =
        IFloatVault(0xfAe6a9D5b0835ca7e9B090eCe0f57C14899BeDA6);

    /// @dev Fraction of every deposit kept liquid (NOT parked). 500 = 5%.
    uint256 public constant RESERVE_BPS = 500;
    uint256 public constant BPS_DENOM   = 10_000;

    /* ──────────────────────────────────────────────────────────────
       Roles & immutable parameters
       ────────────────────────────────────────────────────────────── */

    address public immutable depositor;
    address public immutable beneficiary;
    /// @dev Set to address(0) to disable dispute resolution. Without an
    ///      arbiter the contract still works for happy-path release/refund.
    address public immutable arbiter;
    uint256 public immutable amount;       // original deposit (principal)
    uint256 public immutable timeoutAt;    // depositor can auto-refund after this
    uint256 public immutable createdAt;

    /* ──────────────────────────────────────────────────────────────
       State machine
       ────────────────────────────────────────────────────────────── */

    enum State {
        ACTIVE,    // 0 — funds locked, parties can act
        RELEASED,  // 1 — paid to beneficiary
        REFUNDED,  // 2 — returned to depositor
        DISPUTED   // 3 — parties at impasse, only arbiter can act
    }

    State public state;

    /* ──────────────────────────────────────────────────────────────
       Events
       ────────────────────────────────────────────────────────────── */

    event EscrowCreated     (address indexed depositor, address indexed beneficiary, address arbiter, uint256 amount, uint256 timeoutAt);
    event Parked            (uint256 amount);
    event Disputed          (address indexed by);
    event Released          (address indexed beneficiary, uint256 amount, bool shortfall, bool viaArbiter);
    event Refunded          (address indexed depositor, uint256 amount, bool shortfall, bool viaArbiter);
    event VaultRecallFailed (string reason);

    /* ──────────────────────────────────────────────────────────────
       Constructor — pull USDC, park (1 - reserve), open escrow
       ────────────────────────────────────────────────────────────── */

    constructor(
        address _beneficiary,
        address _arbiter,
        uint256 _amount,
        uint256 _timeoutSeconds
    ) {
        require(_beneficiary != address(0),     "zero beneficiary");
        require(_beneficiary != msg.sender,     "beneficiary == depositor");
        require(_amount > 0,                    "zero amount");
        require(RESERVE_BPS <= BPS_DENOM,       "reserve > 100% (fork bug)");

        // Arbiter must not be either party — otherwise they could `dispute()`
        // then resolve to themselves, bypassing the depositor-approval or
        // timeout requirements that protect the other party.
        if (_arbiter != address(0)) {
            require(_arbiter != msg.sender,     "arbiter == depositor");
            require(_arbiter != _beneficiary,   "arbiter == beneficiary");
        }

        depositor   = msg.sender;
        beneficiary = _beneficiary;
        arbiter     = _arbiter;
        amount      = _amount;
        timeoutAt   = block.timestamp + _timeoutSeconds;
        createdAt   = block.timestamp;
        state       = State.ACTIVE;

        // Pull USDC from depositor. Depositor must have pre-approved.
        USDC.safeTransferFrom(msg.sender, address(this), _amount);

        // ───────────────── FLOAT ─────────────────
        // Park only (1 - RESERVE_BPS) of the deposit. The reserve stays
        // liquid as a safety buffer against any NAV underperformance.
        uint256 parkAmount = (_amount * (BPS_DENOM - RESERVE_BPS)) / BPS_DENOM;
        if (parkAmount > 0) {
            USDC.forceApprove(address(FLOAT_VAULT), parkAmount);
            FLOAT_VAULT.park(parkAmount);
            emit Parked(parkAmount);
        }
        // ─────────────────────────────────────────

        emit EscrowCreated(msg.sender, _beneficiary, _arbiter, _amount, timeoutAt);
    }

    /* ──────────────────────────────────────────────────────────────
       release — send the escrowed amount to the beneficiary
       ──────────────────────────────────────────────────────────────
       Authorized callers:
         · ACTIVE   → only depositor (the happy path: "I approve, pay them")
         · DISPUTED → only arbiter   (resolution: "the beneficiary wins")
       ────────────────────────────────────────────────────────────── */

    function release() external nonReentrant {
        require(state == State.ACTIVE || state == State.DISPUTED, "not active");
        bool viaArbiter = (state == State.DISPUTED);
        if (viaArbiter) {
            require(msg.sender == arbiter,   "only arbiter");
        } else {
            require(msg.sender == depositor, "only depositor");
        }
        _recallAndTransfer(beneficiary, true, viaArbiter);
    }

    /* ──────────────────────────────────────────────────────────────
       refund — return the escrowed amount to the depositor
       ──────────────────────────────────────────────────────────────
       Authorized callers:
         · ACTIVE   → beneficiary (voluntary cancellation: "deal's off")
                      OR depositor after timeout (depositor's safety net)
         · DISPUTED → only arbiter (resolution: "the depositor wins")
       ────────────────────────────────────────────────────────────── */

    function refund() external nonReentrant {
        require(state == State.ACTIVE || state == State.DISPUTED, "not active");
        bool viaArbiter = (state == State.DISPUTED);
        if (viaArbiter) {
            require(msg.sender == arbiter, "only arbiter");
        } else {
            require(
                msg.sender == beneficiary ||
                (msg.sender == depositor && block.timestamp >= timeoutAt),
                "not authorized"
            );
        }
        _recallAndTransfer(depositor, false, viaArbiter);
    }

    /* ──────────────────────────────────────────────────────────────
       dispute — flag a dispute, freezing the escrow until arbiter acts
       ────────────────────────────────────────────────────────────── */

    function dispute() external {
        require(state == State.ACTIVE,                       "not active");
        require(arbiter != address(0),                       "no arbiter set");
        require(msg.sender == depositor || msg.sender == beneficiary, "not party");
        state = State.DISPUTED;
        emit Disputed(msg.sender);
    }

    /* ──────────────────────────────────────────────────────────────
       Internal: recall from FLOAT and transfer everything to recipient
       ────────────────────────────────────────────────────────────── */

    function _recallAndTransfer(address recipient, bool isRelease, bool viaArbiter) internal {
        // CEI: update state BEFORE external calls.
        state = isRelease ? State.RELEASED : State.REFUNDED;

        // ───────────────── FLOAT ─────────────────
        // Recall everything before payout. Wrapped in try/catch so a vault
        // failure can't lock the contract — recipient still gets whatever's
        // liquid (just less than amount in that case).
        uint256 parked;
        try FLOAT_VAULT.deposits(address(this)) returns (uint256 _parked) {
            parked = _parked;
        } catch {
            parked = 0;
        }

        if (parked > 0) {
            try FLOAT_VAULT.withdraw(parked) {
                // success — funds returned to this contract
            } catch Error(string memory reason) {
                emit VaultRecallFailed(reason);
            } catch {
                emit VaultRecallFailed("unknown");
            }
        }
        // ─────────────────────────────────────────

        uint256 liquid    = USDC.balanceOf(address(this));
        bool    shortfall = liquid < amount;

        if (liquid > 0) {
            USDC.safeTransfer(recipient, liquid);
        }

        if (isRelease) {
            emit Released(recipient, liquid, shortfall, viaArbiter);
        } else {
            emit Refunded(recipient, liquid, shortfall, viaArbiter);
        }
    }

    /* ──────────────────────────────────────────────────────────────
       Views
       ────────────────────────────────────────────────────────────── */

    function totalAssets() external view returns (uint256 liquid, uint256 parked) {
        liquid = USDC.balanceOf(address(this));
        parked = FLOAT_VAULT.deposits(address(this));
    }

    function isExpired() external view returns (bool) {
        return block.timestamp >= timeoutAt;
    }
}
