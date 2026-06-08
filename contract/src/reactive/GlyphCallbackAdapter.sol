// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
import {IReputationRegistry} from "../interfaces/IReputationRegistry.sol";

/// @title  GlyphCallbackAdapter
/// @author Glyph (P2 — Smart path)
/// @notice Destination-chain landing pad for `GlyphReactive`'s cross-pool callbacks.
///
///         The Reactive Network's callback proxy invokes `glyphCallback(...)` here, injecting
///         the originating RVM id as the first argument. This adapter validates the proxy
///         (`authorizedSenderOnly`) and the RVM id (`rvmIdOnly`), then forwards to
///         `ReputationRegistry.updateScoreFromReactive`.
///
/// @dev    This indirection is deliberate: the Reactive callback ABI requires an
///         address-first signature, which is incompatible with the frozen
///         `updateScoreFromReactive(address wallet, uint16)` seam. Routing through this
///         adapter — registered in the registry as its `reactiveProxy` — keeps the
///         `IReputationRegistry` interface untouched while remaining a faithful Reactive
///         callback contract.
contract GlyphCallbackAdapter is AbstractCallback {
    IReputationRegistry public immutable registry;
    address public owner;

    event CrossPoolScoreApplied(address indexed wallet, uint16 aggregateScore);
    event RvmIdSet(address indexed rvmId);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param _callbackSender The Reactive Network callback proxy address on THIS (destination) chain.
    /// @param _registry       The ReputationRegistry this adapter feeds.
    constructor(address _callbackSender, IReputationRegistry _registry) AbstractCallback(_callbackSender) {
        owner = msg.sender;
        registry = _registry;
        // Default to accepting any RVM id so the demo works before the RSC is deployed.
        // Tighten in production via setRvmId(<GlyphReactive RVM id>) — authorizedSenderOnly
        // (proxy address) remains the primary gate regardless.
        rvm_id = address(0);
    }

    /// @param rvmId          Injected by the Reactive Network — the originating RSC's RVM id.
    /// @param wallet         Wallet whose cross-pool score should be raised.
    /// @param aggregateScore Aggregate severity-derived score (0..10_000).
    function glyphCallback(address rvmId, address wallet, uint16 aggregateScore)
        external
        authorizedSenderOnly
        rvmIdOnly(rvmId)
    {
        registry.updateScoreFromReactive(wallet, aggregateScore);
        emit CrossPoolScoreApplied(wallet, aggregateScore);
    }

    /// @notice Restrict accepted callbacks to a specific RVM id (the deployed GlyphReactive).
    function setRvmId(address _rvmId) external onlyOwner {
        rvm_id = _rvmId;
        emit RvmIdSet(_rvmId);
    }

    /// @notice Authorize an additional callback sender (e.g. a second proxy). Owner-gated.
    function authorizeSender(address sender) external onlyOwner {
        addAuthorizedSender(sender);
    }
}
