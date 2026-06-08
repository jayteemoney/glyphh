// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {IReputationRegistry} from "../interfaces/IReputationRegistry.sol";

/// @title  GlyphReactive
/// @author Glyph (P2 — Smart path)
/// @notice The cross-pool engine. A Reactive Smart Contract (deployed on the Reactive
///         Network / Kopli) that turns every Glyph pool into a sensor for every other.
///
///         It subscribes — once — to `ToxicTradeReported` events from the ReputationRegistry
///         on the origin chain. Because *every* Glyph hook reports to that single registry,
///         one subscription captures toxicity from all pools. The RSC keeps a per-wallet
///         cross-pool aggregate and, when a wallet's average severity crosses the dispatch
///         threshold, emits a Reactive `Callback` that raises that wallet's score on the
///         destination chain via `GlyphCallbackAdapter -> ReputationRegistry.updateScoreFromReactive`.
///
/// @dev    Two copies of this contract exist: the Reactive Network instance (`vm == false`),
///         which owns the subscription, and the ReactVM instance (`vm == true`), where
///         `react()` executes. The `AbstractReactive` base distinguishes them via `detectVm()`.
contract GlyphReactive is AbstractReactive {
    // ── Constants ─────────────────────────────────────────────────────────────

    /// @dev topic0 of ToxicTradeReported(address indexed wallet, address indexed pool, uint16 localSeverity, uint256 timestamp)
    uint256 private constant TOXIC_TRADE_TOPIC_0 =
        uint256(keccak256("ToxicTradeReported(address,address,uint16,uint256)"));

    uint64 public constant CALLBACK_GAS_LIMIT = 200_000;
    uint32 public constant MAX_AGGREGATE_COUNT = 1_000;
    /// @notice Average severity (0..10_000) at/above which a wallet is propagated cross-pool.
    uint16 public constant DISPATCH_THRESHOLD = 500;
    uint16 public constant MAX_SCORE = 10_000;

    // ── Storage ───────────────────────────────────────────────────────────────

    struct Aggregate {
        uint32 count; // number of toxic reports seen across all pools
        uint64 scoreSum; // saturating sum of localSeverity
        uint64 lastUpdated; // block.timestamp of the last report
        uint16 lastDispatched; // last score pushed cross-pool (dispatch hysteresis)
    }

    uint256 public immutable originChainId; // chain that emits ToxicTradeReported (e.g. Unichain Sepolia)
    uint256 public immutable destinationChainId; // chain the callback lands on (same registry chain)
    address public immutable registry; // ReputationRegistry on origin (the event source)
    address public immutable callbackAdapter; // GlyphCallbackAdapter on destination (callback target)
    address public owner;

    bool public paused;
    mapping(address => Aggregate) public aggregates;

    // ── Events ────────────────────────────────────────────────────────────────

    event AggregateUpdated(address indexed wallet, uint64 scoreSum, uint32 count, uint16 avgSeverity);
    event CrossPoolDispatch(address indexed wallet, uint16 aggregateScore);
    event Subscribed(uint256 indexed chainId, address indexed registry);
    event PausedSet(bool paused);

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 _originChainId, uint256 _destinationChainId, address _registry, address _callbackAdapter) {
        owner = msg.sender;
        originChainId = _originChainId;
        destinationChainId = _destinationChainId;
        registry = _registry;
        callbackAdapter = _callbackAdapter;

        // Subscribe only on the Reactive Network instance; the ReactVM copy must not.
        if (!vm) {
            service.subscribe(
                _originChainId, _registry, TOXIC_TRADE_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            emit Subscribed(_originChainId, _registry);
        }
    }

    // ── Reactive entry point (runs on the ReactVM) ───────────────────────────────

    /// @inheritdoc IReactive
    function react(LogRecord calldata log) external vmOnly {
        // Defensive filtering — only our event, from our registry, on our origin chain.
        if (log.chain_id != originChainId) return;
        if (log._contract != registry) return;
        if (log.topic_0 != TOXIC_TRADE_TOPIC_0) return;
        if (log.data.length < 32) return;

        address wallet = address(uint160(log.topic_1)); // indexed wallet
        uint16 localSeverity = uint16(uint256(bytes32(log.data[0:32]))); // first non-indexed data word

        Aggregate storage agg = aggregates[wallet];
        if (agg.count < MAX_AGGREGATE_COUNT) {
            unchecked {
                agg.count += 1;
            }
        }

        uint64 newSum = agg.scoreSum + localSeverity;
        if (newSum < agg.scoreSum) newSum = type(uint64).max; // saturate, never wrap
        agg.scoreSum = newSum;
        agg.lastUpdated = uint64(block.timestamp);

        uint256 avg = agg.count == 0 ? 0 : uint256(agg.scoreSum) / agg.count;
        uint16 aggregateScore = avg > MAX_SCORE ? MAX_SCORE : uint16(avg);

        emit AggregateUpdated(wallet, agg.scoreSum, agg.count, aggregateScore);

        // Dispatch only when above threshold AND strictly higher than the last dispatch.
        // Hysteresis avoids spamming callbacks (real REACT cost) for an already-flagged wallet.
        if (!paused && aggregateScore >= DISPATCH_THRESHOLD && aggregateScore > agg.lastDispatched) {
            agg.lastDispatched = aggregateScore;
            _dispatch(wallet, aggregateScore);
        }
    }

    // ── Admin (Reactive Network instance only) ───────────────────────────────────

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Re-establish the subscription if it was dropped (ops escape hatch).
    function subscribe() external onlyOwner rnOnly {
        service.subscribe(
            originChainId, registry, TOXIC_TRADE_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        emit Subscribed(originChainId, registry);
    }

    function unsubscribe() external onlyOwner rnOnly {
        service.unsubscribe(
            originChainId, registry, TOXIC_TRADE_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _dispatch(address wallet, uint16 aggregateScore) internal {
        // The Reactive Network overwrites the first address argument of the callback with the
        // originating RVM id, so the adapter's signature leads with that injected address.
        bytes memory payload = abi.encodeWithSignature(
            "glyphCallback(address,address,uint16)",
            address(0), // placeholder — system fills the RVM id
            wallet,
            aggregateScore
        );
        emit CrossPoolDispatch(wallet, aggregateScore);
        emit Callback(destinationChainId, callbackAdapter, CALLBACK_GAS_LIMIT, payload);
    }
}
