// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title  IRebateVault
/// @notice Escrow for sandwich surcharges, credited by the hook and claimed by victims.
///
/// @dev    This is the piece that makes Glyph's answer to sandwiching different from every
///         "charge the attacker more" hook. The surcharge on a sandwich's closing leg does
///         *not* go to in-range LPs through the fee override, because the party harmed by a
///         sandwich is not the LP — it is the trader who got squeezed in the middle. The hook
///         takes the surcharge as a delta and credits it here, to that trader by address.
interface IRebateVault {
    event RebateCredited(address indexed victim, Currency indexed currency, uint256 amount, address indexed hook);
    event RebateClaimed(address indexed victim, Currency indexed currency, uint256 amount);
    event HookAuthorized(address indexed hook, bool authorized);

    error Unauthorized();
    error NothingToClaim();

    /// @notice Credit `amount` of `currency` to `victim`. Callable only by an authorized hook,
    ///         which must already have transferred the funds to this contract.
    function credit(Currency currency, address victim, uint256 amount) external;

    /// @notice Amount of `currency` that `victim` can currently withdraw.
    function claimable(address victim, Currency currency) external view returns (uint256);

    /// @notice Withdraw the caller's full balance of `currency`.
    function claim(Currency currency) external returns (uint256 amount);
}
