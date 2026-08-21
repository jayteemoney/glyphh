// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReputationRegistry} from "./IReputationRegistry.sol";

/// @title  IGlyphRegistry
/// @notice The v2 registry surface: everything in the frozen v1 interface, plus a *trust*
///         dimension and a pool-aware toxicity report.
///
/// @dev    Deliberately additive. `IReputationRegistry` is frozen and stays frozen — the v1
///         registry already deployed on Unichain Sepolia keeps working, and every v1 test
///         keeps passing. Two things are new:
///
///         1. **Trust.** v1 could only ever make a swap more expensive. v2 needs the opposite
///            direction too, because that is what makes wallet rotation costly: an attacker
///            who rotates does not escape a penalty, they forfeit a discount that took real
///            benign volume to earn. Trust is attested over its own EIP-712 typehash with its
///            own nonce sequence, so it cannot be forged from a captured score attestation.
///
///         2. **Pool-aware reporting.** v1's `reportToxicTrade` took an `address pool`, and
///            the hook passed its own address into it — so every pool behind a single hook
///            reported as one pool, and the cross-pool aggregate could not actually
///            distinguish them. `reportToxicSwap` takes the real `PoolId`.
interface IGlyphRegistry is IReputationRegistry {
    /// @notice A signed claim that `wallet` has earned trust `value`.
    /// @dev    Structurally identical to `Attestation` but a distinct type with a distinct
    ///         typehash and a distinct nonce sequence. Keeping them separate is what stops a
    ///         score attestation from being replayed as a trust attestation.
    struct TrustAttestation {
        address wallet;
        uint16 value;
        uint32 nonce;
        uint64 deadline;
        bytes signature;
    }

    event TrustUpdated(address indexed wallet, uint16 value, uint32 nonce);
    event ToxicSwapReported(address indexed wallet, bytes32 indexed poolId, uint16 severity, uint256 timestamp);
    event AttestorAuthorized(address indexed attestor, bool authorized);

    /// @notice Decay-adjusted trust for `wallet`, 0..10_000. This is what buys the fee down.
    function trustOf(address wallet) external view returns (uint16);

    /// @notice Raw stored trust (value as of `updatedAt`, plus the last-accepted nonce).
    function trustDataOf(address wallet) external view returns (Score memory);

    /// @notice Apply a signed trust attestation from an authorized attestor.
    function updateTrust(TrustAttestation calldata attestation) external;

    /// @notice Report a locally-toxic swap against the pool it actually happened in.
    function reportToxicSwap(address wallet, bytes32 poolId, uint16 severity) external;
}
