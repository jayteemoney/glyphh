// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IRebateVault} from "./interfaces/IRebateVault.sol";

/// @title  RebateVault
/// @notice Escrow that returns sandwich surcharges to the traders who were sandwiched.
///
/// @dev    Glyph's other premiums — the arbitrage premium and the toxicity premium — are paid
///         to in-range LPs through v4's dynamic fee override, because LPs are who those forms
///         of flow extract from. A sandwich is different: the party who loses is the trader
///         squeezed between the two legs, not the LP. Paying that surcharge to LPs would
///         leave the actual victim exactly as badly off, so the closing leg's surcharge is
///         taken as a hook delta and routed here instead, credited to the victim by address.
///
///         Funds arrive by direct transfer from the hook (`poolManager.take(..., vault, ...)`)
///         and are then attributed by a separate `credit` call. Splitting movement from
///         attribution keeps this contract free of any v4 knowledge — it never touches the
///         PoolManager, never holds a lock, and never participates in flash accounting.
contract RebateVault is IRebateVault, Ownable, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;

    /// @notice Hooks permitted to attribute incoming funds.
    mapping(address hook => bool authorized) private _authorizedHooks;

    /// @notice Unclaimed balance per victim, per currency.
    mapping(address victim => mapping(Currency currency => uint256 amount)) private _claimable;

    /// @notice Total credited but not yet claimed, per currency.
    /// @dev    Tracked so `credit` can refuse to attribute more than the vault actually holds.
    ///         Without it a miscomputed delta in the hook would silently create claims the
    ///         vault cannot honour, and the shortfall would land on whichever victim happened
    ///         to claim last. Failing at attribution time makes that a hook bug, caught in the
    ///         hook's own tests, rather than a user-facing insolvency much later.
    mapping(Currency currency => uint256 total) public outstanding;

    error InsufficientBalance();

    constructor(address _owner) Ownable(_owner) {}

    // ── Writes ────────────────────────────────────────────────────────────────

    /// @inheritdoc IRebateVault
    function credit(Currency currency, address victim, uint256 amount) external override {
        if (!_authorizedHooks[msg.sender]) revert Unauthorized();
        if (amount == 0) return;

        // The hook transfers first and attributes second, so the funds must already be here.
        if (currency.balanceOfSelf() < outstanding[currency] + amount) revert InsufficientBalance();

        unchecked {
            _claimable[victim][currency] += amount;
            outstanding[currency] += amount;
        }

        emit RebateCredited(victim, currency, amount, msg.sender);
    }

    /// @inheritdoc IRebateVault
    function claim(Currency currency) external override nonReentrant returns (uint256 amount) {
        amount = _claimable[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();

        // Checks-effects-interactions: zero the ledger before any transfer, so a currency
        // with a transfer hook cannot re-enter and claim the same balance twice. The
        // reentrancy guard is belt to this contract's braces.
        _claimable[msg.sender][currency] = 0;
        unchecked {
            outstanding[currency] -= amount;
        }

        currency.transfer(msg.sender, amount);
        emit RebateClaimed(msg.sender, currency, amount);
    }

    // ── Reads ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IRebateVault
    function claimable(address victim, Currency currency) external view override returns (uint256) {
        return _claimable[victim][currency];
    }

    /// @notice Whether `hook` may attribute funds held by this vault.
    function isAuthorizedHook(address hook) external view returns (bool) {
        return _authorizedHooks[hook];
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setHook(address hook, bool authorized) external onlyOwner {
        _authorizedHooks[hook] = authorized;
        emit HookAuthorized(hook, authorized);
    }

    /// @notice Accept native currency sent by the hook ahead of a `credit` call.
    receive() external payable {}
}
