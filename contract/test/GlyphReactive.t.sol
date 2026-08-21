// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {GlyphReactive} from "../src/reactive/GlyphReactive.sol";
import {GlyphCallbackAdapter} from "../src/reactive/GlyphCallbackAdapter.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";

/// @dev In a local Foundry run there is no system contract at 0x…fffFfF, so AbstractReactive's
///      detectVm() sets vm = true. That means: (1) the constructor skips `service.subscribe`,
///      and (2) `react()` (vmOnly) is directly callable — exactly the ReactVM code path we test.
contract GlyphReactiveTest is Test {
    uint256 constant ORIGIN_CHAIN = 1301;
    uint256 constant DEST_CHAIN = 1301;
    address constant REGISTRY = address(0xdeadbeef);
    address constant ADAPTER = address(0xad);
    address constant WALLET = address(0xB0B);
    bytes32 constant POOL_A = keccak256("POOL_A");
    bytes32 constant POOL_B = keccak256("POOL_B");

    uint256 constant TOXIC_TOPIC0 = uint256(keccak256("ToxicSwapReported(address,bytes32,uint16,uint256)"));

    GlyphReactive reactive;

    function setUp() public {
        reactive = new GlyphReactive(ORIGIN_CHAIN, DEST_CHAIN, REGISTRY, ADAPTER);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _log(address contract_, uint256 chainId, address wallet, bytes32 poolId, uint16 severity)
        internal
        view
        returns (IReactive.LogRecord memory log)
    {
        log.chain_id = chainId;
        log._contract = contract_;
        log.topic_0 = TOXIC_TOPIC0;
        log.topic_1 = uint256(uint160(wallet));
        log.topic_2 = uint256(poolId);
        log.data = abi.encode(severity, uint256(block.timestamp));
        log.block_number = block.number;
    }

    // ── Aggregation ──────────────────────────────────────────────────────────────

    function test_react_aggregatesSeverity() public {
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 400));
        (uint32 count, uint64 sum,, uint16 lastDispatched,) = reactive.aggregates(WALLET);
        assertEq(count, 1);
        assertEq(sum, 400);
        // 400 avg < DISPATCH_THRESHOLD (500) → no dispatch yet
        assertEq(lastDispatched, 0);
    }

    function test_react_dispatchesWhenThresholdCrossed() public {
        // First report below threshold: avg 400 < 500 → aggregated but not dispatched. It is
        // also a single pool, which on its own would hold the dispatch back regardless.
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 400));
        (,,, uint16 d0,) = reactive.aggregates(WALLET);
        assertEq(d0, 0);

        // Second report lifts avg to (400+800)/2 = 600 ≥ 500 → cross-pool dispatch.
        vm.expectEmit(true, false, false, true);
        emit GlyphReactive.CrossPoolDispatch(WALLET, 600);
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_B, 800));

        (,,, uint16 d1,) = reactive.aggregates(WALLET);
        assertEq(d1, 600);
    }

    function test_react_emitsCallbackToAdapter() public {
        // Needs two distinct pools: one pool's problem is that pool's own to price.
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 10_000));

        bytes memory payload =
            abi.encodeWithSignature("glyphCallback(address,address,uint16)", address(0), WALLET, uint16(10_000));
        vm.expectEmit(true, true, true, true);
        emit IReactive.Callback(DEST_CHAIN, ADAPTER, reactive.CALLBACK_GAS_LIMIT(), payload);
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_B, 10_000));
    }

    // ── Distinct-pool gate ───────────────────────────────────────────────────────

    /// @dev The claim is "every pool is a sensor for every other". v1 could not actually tell
    ///      pools apart -- the hook passed its own address where the pool belonged -- so
    ///      repeat offences in a single pool looked like cross-pool activity and triggered a
    ///      callback that bought nothing and cost real REACT.
    function test_react_singlePoolNeverDispatches() public {
        for (uint256 i = 0; i < 5; i++) {
            reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 10_000));
        }
        (,,, uint16 lastDispatched, uint16 distinctPools) = reactive.aggregates(WALLET);
        assertEq(distinctPools, 1, "one pool seen");
        assertEq(lastDispatched, 0, "must not propagate a single pool's local problem");
    }

    function test_react_secondPoolUnlocksDispatch() public {
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 10_000));
        (,,, uint16 before,) = reactive.aggregates(WALLET);
        assertEq(before, 0);

        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_B, 10_000));
        (,,, uint16 afterSecond, uint16 distinctPools) = reactive.aggregates(WALLET);
        assertEq(distinctPools, 2);
        assertEq(afterSecond, 10_000);
    }

    function test_react_distinctPoolsIsSetCardinality() public {
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 100));
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 100));
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 100));
        (,,,, uint16 distinctPools) = reactive.aggregates(WALLET);
        assertEq(distinctPools, 1, "repeat reports in one pool must not inflate the count");
    }

    function test_react_emitsPoolObserved() public {
        vm.expectEmit(true, true, false, true);
        emit GlyphReactive.PoolObserved(WALLET, POOL_A, 1);
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 100));
    }

    function test_react_hysteresis_noRedispatchAtSameLevel() public {
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 10_000)); // pool 1, no dispatch yet
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_B, 10_000)); // pool 2, dispatch @ 10_000
        // A third report keeps avg at 10_000, which is not strictly greater than lastDispatched,
        // so no further callback fires -- the hysteresis that keeps REACT costs bounded.
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, keccak256("POOL_C"), 10_000));
        (,,, uint16 lastDispatched,) = reactive.aggregates(WALLET);
        assertEq(lastDispatched, 10_000);
    }

    // ── Filtering ────────────────────────────────────────────────────────────────

    function test_react_ignoresWrongChain() public {
        reactive.react(_log(REGISTRY, 999, WALLET, POOL_A, 10_000));
        (uint32 count,,,,) = reactive.aggregates(WALLET);
        assertEq(count, 0);
    }

    function test_react_ignoresWrongContract() public {
        reactive.react(_log(address(0xDEAD), ORIGIN_CHAIN, WALLET, POOL_A, 10_000));
        (uint32 count,,,,) = reactive.aggregates(WALLET);
        assertEq(count, 0);
    }

    function test_react_aggregateCountCaps() public {
        // Saturating sum + bounded count keep storage growth in check.
        for (uint256 i = 0; i < 5; i++) {
            reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 100));
        }
        (uint32 count, uint64 sum,,,) = reactive.aggregates(WALLET);
        assertEq(count, 5);
        assertEq(sum, 500);
    }

    // ── Admin ────────────────────────────────────────────────────────────────────

    function test_setPaused_blocksDispatch() public {
        reactive.setPaused(true);
        reactive.react(_log(REGISTRY, ORIGIN_CHAIN, WALLET, POOL_A, 10_000));
        (,,, uint16 lastDispatched,) = reactive.aggregates(WALLET);
        assertEq(lastDispatched, 0); // aggregated but not dispatched
    }

    function test_setPaused_RevertWhenNotOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(GlyphReactive.NotOwner.selector);
        reactive.setPaused(true);
    }
}

/// @dev Tests the destination-side adapter that bridges the Reactive callback ABI to the
///      frozen `updateScoreFromReactive` seam.
contract GlyphCallbackAdapterTest is Test {
    address constant OWNER = address(0xD1);
    address constant PROXY = address(0xCA11); // the Reactive callback proxy (authorized sender)
    address constant WALLET = address(0xB0B);

    ReputationRegistry registry;
    GlyphCallbackAdapter adapter;

    function setUp() public {
        registry = new ReputationRegistry(OWNER);
        adapter = new GlyphCallbackAdapter(PROXY, IReputationRegistry(address(registry)));
        vm.prank(OWNER);
        registry.setReactiveProxy(address(adapter));
    }

    function test_glyphCallback_raisesScore() public {
        vm.prank(PROXY);
        adapter.glyphCallback(address(0), WALLET, 7_000);
        assertEq(registry.scoreOf(WALLET), 7_000);
    }

    function test_glyphCallback_emitsApplied() public {
        vm.expectEmit(true, false, false, true);
        emit GlyphCallbackAdapter.CrossPoolScoreApplied(WALLET, 7_000);
        vm.prank(PROXY);
        adapter.glyphCallback(address(0), WALLET, 7_000);
    }

    function test_glyphCallback_RevertWhenUnauthorizedSender() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("Authorized sender only"));
        adapter.glyphCallback(address(0), WALLET, 7_000);
    }

    function test_setRvmId_thenMismatchReverts() public {
        vm.prank(adapter.owner());
        adapter.setRvmId(address(0xc0ffee));
        vm.prank(PROXY);
        vm.expectRevert(bytes("Authorized RVM ID only"));
        adapter.glyphCallback(address(0xBEEF), WALLET, 7_000); // wrong rvm id
    }
}
