// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for FloatVault on Arc Testnet.
///         Deployed at: 0xfAe6a9D5b0835ca7e9B090eCe0f57C14899BeDA6
///
/// @dev    Caller must `approve(vault, amount)` on USDC before `park(amount)`.
///         `deposits[addr]` returns the principal currently held by the vault
///         on behalf of `addr`. Use this value for `withdraw()` to avoid stale
///         in-memory accounting (a.k.a. ESTIMATION_ERROR).
interface IFloatVault {
    function park(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function deposits(address account) external view returns (uint256);
    function totalDeposits() external view returns (uint256);
}
