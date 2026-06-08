// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";

/// @title  ReputationRegistry
/// @author Glyph (P2 — Smart path)
/// @notice Canonical per-wallet reputation store for Glyph. Holds a 0..10_000
///         toxicity score for every wallet, written by three trust-separated paths:
///           1. `updateScore`            — off-chain ML detector, EIP-712 signed.
///           2. `reportToxicTrade`       — authorized Glyph hooks, on a locally-toxic swap.
///           3. `updateScoreFromReactive`— the Reactive Network callback proxy (cross-pool).
/// @dev    Scores decay linearly to zero over `DECAY_PERIOD` since their last update, so
///         reputation is a *living* signal: a wallet that stops trading toxically recovers
///         automatically and there is no permanent blacklist. Reads (`scoreOf`) project the
///         decay forward; writes re-baseline to "now" so historical toxicity cannot be fully
///         resurrected by a single minor new trade.
///
///         This contract implements the frozen `IReputationRegistry` seam exactly; every
///         addition here (errors, events, batch/getters) is purely additive and does not
///         change that interface.
contract ReputationRegistry is IReputationRegistry, EIP712, Ownable {
    // ── Constants ─────────────────────────────────────────────────────────────

    bytes32 public constant SCORE_TYPEHASH =
        keccak256("Score(address wallet,uint16 value,uint32 nonce,uint64 deadline)");

    uint16 public constant MAX_SCORE = 10_000;

    /// @notice A score fully decays to zero this long after its last update.
    uint64 public constant DECAY_PERIOD = 7 days;

    /// @notice Reject attestations whose deadline is further out than this. Caps the
    ///         replay window even though monotonic nonces already prevent reuse.
    uint64 public constant MAX_DEADLINE_WINDOW = 1 hours;

    // ── Errors (additive to the frozen interface) ─────────────────────────────

    error DeadlineTooFar();

    // ── Events (additive to the frozen interface) ─────────────────────────────

    event AttestorAuthorized(address indexed attestor, bool authorized);
    event ReactiveProxyUpdated(address indexed proxy);

    // ── Storage (append-only; never reorder for storage-layout stability) ─────

    mapping(address => Score) private _scores;
    mapping(address => bool) private _authorizedHooks;
    mapping(address => bool) private _authorizedAttestors;
    address public reactiveProxy;

    constructor(address _owner) EIP712("GlyphReputationRegistry", "1") Ownable(_owner) {}

    // ── Writes ────────────────────────────────────────────────────────────────

    /// @inheritdoc IReputationRegistry
    function updateScore(Attestation calldata attestation) external override {
        _applyAttestation(attestation);
    }

    /// @notice Atomically apply many signed attestations in one transaction.
    /// @dev    All-or-nothing: a single invalid attestation reverts the whole batch.
    ///         Lets the detector refresh a cohort of wallets cheaply on a schedule.
    function updateScoreBatch(Attestation[] calldata attestations) external {
        for (uint256 i = 0; i < attestations.length;) {
            _applyAttestation(attestations[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IReputationRegistry
    function reportToxicTrade(address wallet, address pool, uint16 localSeverity) external override {
        if (!_authorizedHooks[msg.sender]) revert Unauthorized();

        Score storage stored = _scores[wallet];
        // Re-baseline to the decayed value before adding, so stale toxicity fades correctly.
        uint256 next = uint256(_decayed(stored.value, stored.updatedAt)) + uint256(localSeverity) / 2;
        if (next > MAX_SCORE) next = MAX_SCORE;

        stored.value = uint16(next);
        stored.updatedAt = uint64(block.timestamp);

        emit ToxicTradeReported(wallet, pool, localSeverity, block.timestamp);
    }

    /// @inheritdoc IReputationRegistry
    function updateScoreFromReactive(address wallet, uint16 aggregateScore) external override {
        if (msg.sender != reactiveProxy) revert Unauthorized();
        if (aggregateScore > MAX_SCORE) revert ScoreOutOfRange();

        Score storage stored = _scores[wallet];
        // Cross-pool aggregate can only raise the score, and only above the decayed current value.
        if (aggregateScore > _decayed(stored.value, stored.updatedAt)) {
            stored.value = aggregateScore;
            stored.updatedAt = uint64(block.timestamp);
            emit ScoreUpdated(wallet, aggregateScore, stored.nonce);
        }
    }

    // ── Reads ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IReputationRegistry
    /// @dev Effective, decay-adjusted score — this is what the hook prices fees on.
    function scoreOf(address wallet) external view override returns (uint16) {
        Score memory s = _scores[wallet];
        return _decayed(s.value, s.updatedAt);
    }

    /// @inheritdoc IReputationRegistry
    /// @dev Raw stored score (value as of `updatedAt`, plus `nonce`). Off-chain consumers
    ///      recompute decay from `updatedAt`; `nonce` is the last-accepted attestation nonce.
    function scoreDataOf(address wallet) external view override returns (Score memory) {
        return _scores[wallet];
    }

    /// @inheritdoc IReputationRegistry
    function isAuthorizedHook(address hook) external view override returns (bool) {
        return _authorizedHooks[hook];
    }

    /// @notice Whether `attestor` is in the authorized signer set.
    function isAuthorizedAttestor(address attestor) external view returns (bool) {
        return _authorizedAttestors[attestor];
    }

    /// @notice EIP-712 domain separator, exposed for off-chain signers and tooling.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ── Admin (Ownable) ─────────────────────────────────────────────────────────

    function setHook(address hook, bool authorized) external onlyOwner {
        _authorizedHooks[hook] = authorized;
        emit HookAuthorized(hook, authorized);
    }

    function setAttestor(address attestor, bool authorized) external onlyOwner {
        _authorizedAttestors[attestor] = authorized;
        emit AttestorAuthorized(attestor, authorized);
    }

    function setReactiveProxy(address proxy) external onlyOwner {
        reactiveProxy = proxy;
        emit ReactiveProxyUpdated(proxy);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _applyAttestation(Attestation calldata a) internal {
        if (block.timestamp > a.deadline) revert ExpiredDeadline();
        if (a.deadline > block.timestamp + MAX_DEADLINE_WINDOW) revert DeadlineTooFar();
        if (a.value > MAX_SCORE) revert ScoreOutOfRange();

        address signer = ECDSA.recover(_buildDigest(a), a.signature);
        if (!_authorizedAttestors[signer]) revert InvalidSignature();

        Score storage stored = _scores[a.wallet];
        // Strictly monotonic per-wallet nonce — the core replay defense.
        if (a.nonce != stored.nonce + 1) revert NonceTooLow();

        stored.value = a.value;
        stored.updatedAt = uint64(block.timestamp);
        stored.nonce = a.nonce;

        emit ScoreUpdated(a.wallet, a.value, a.nonce);
    }

    /// @dev Linear decay of `value` to zero over `DECAY_PERIOD` since `updatedAt`.
    ///      One SLOAD upstream feeds this; the math here is a handful of cheap ops.
    function _decayed(uint16 value, uint64 updatedAt) internal view returns (uint16) {
        if (value == 0 || updatedAt >= block.timestamp) return value;
        uint256 elapsed = block.timestamp - updatedAt;
        if (elapsed >= DECAY_PERIOD) return 0;
        return uint16(uint256(value) * (DECAY_PERIOD - elapsed) / DECAY_PERIOD);
    }

    function _buildDigest(Attestation calldata a) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(SCORE_TYPEHASH, a.wallet, a.value, a.nonce, a.deadline)));
    }
}
