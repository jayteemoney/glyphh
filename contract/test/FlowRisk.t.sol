// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FlowRisk} from "../src/libraries/FlowRisk.sol";

contract FlowRiskTest is Test {
    // ── L1: directional arbitrage premium ────────────────────────────────────

    function test_arb_gapWideningIsAlwaysFree(uint256 divergenceBps) public pure {
        divergenceBps = bound(divergenceBps, 0, 1_000_000);
        assertEq(FlowRisk.arbPremium(divergenceBps, false), 0);
    }

    function test_arb_noiseBandIsFree() public pure {
        assertEq(FlowRisk.arbPremium(FlowRisk.ARB_TOLERANCE_BPS, true), 0);
        assertEq(FlowRisk.arbPremium(FlowRisk.ARB_TOLERANCE_BPS + 1, true), FlowRisk.ARB_CAPTURE_PCT);
    }

    function test_arb_monotonicInDivergence(uint256 a, uint256 b) public pure {
        a = bound(a, 0, 100_000);
        b = bound(b, a, 100_000);
        assertLe(FlowRisk.arbPremium(a, true), FlowRisk.arbPremium(b, true));
    }

    function test_arb_neverExceedsCap(uint256 divergenceBps) public pure {
        divergenceBps = bound(divergenceBps, 0, type(uint128).max);
        assertLe(FlowRisk.arbPremium(divergenceBps, true), FlowRisk.ARB_PREMIUM_CAP);
    }

    // ── L3a: unproven premium ────────────────────────────────────────────────

    function test_unproven_retailBandIsFree(uint256 sizeBps) public pure {
        sizeBps = bound(sizeBps, 0, FlowRisk.UNPROVEN_FREE_SIZE_BPS);
        assertEq(FlowRisk.unprovenPremium(sizeBps), 0);
    }

    function test_unproven_monotonicInSize(uint256 a, uint256 b) public pure {
        a = bound(a, 0, 100_000);
        b = bound(b, a, 100_000);
        assertLe(FlowRisk.unprovenPremium(a), FlowRisk.unprovenPremium(b));
    }

    function test_unproven_neverExceedsCap(uint256 sizeBps) public pure {
        sizeBps = bound(sizeBps, 0, type(uint128).max);
        assertLe(FlowRisk.unprovenPremium(sizeBps), FlowRisk.UNPROVEN_CAP);
    }

    // ── L3b/c: reputation terms ──────────────────────────────────────────────

    function test_toxic_monotonicInScore(uint16 a, uint16 b) public pure {
        vm.assume(a <= b);
        assertLe(FlowRisk.toxicPremium(a), FlowRisk.toxicPremium(b));
    }

    function test_toxic_endpoints() public pure {
        assertEq(FlowRisk.toxicPremium(0), 0);
        assertEq(FlowRisk.toxicPremium(10_000), FlowRisk.MAX_FEE - FlowRisk.BASE_FEE);
    }

    function test_trustDiscount_monotonicInTrust(uint16 a, uint16 b) public pure {
        vm.assume(a <= b);
        assertLe(FlowRisk.trustDiscount(a), FlowRisk.trustDiscount(b));
    }

    /// @dev Trust alone must never be able to drive the fee below the floor.
    function test_trustDiscount_capped(uint16 trust) public pure {
        assertLe(FlowRisk.trustDiscount(trust), FlowRisk.BASE_FEE - FlowRisk.FLOOR_FEE);
    }

    // ── Assembly ─────────────────────────────────────────────────────────────

    function _inputs(uint256 divergenceBps, bool closesGap, uint256 sizeBps, uint16 score, uint16 trust)
        internal
        pure
        returns (FlowRisk.Inputs memory)
    {
        return FlowRisk.Inputs({
            divergenceBps: divergenceBps,
            closesGap: closesGap,
            sizeBps: sizeBps,
            score: score,
            trust: trust
        });
    }

    function test_assemble_quietPoolIsBaseFee() public pure {
        assertEq(FlowRisk.assembleFee(_inputs(0, false, 0, 0, 0)), FlowRisk.BASE_FEE);
    }

    function test_assemble_maxTrustReachesFloor() public pure {
        assertEq(FlowRisk.assembleFee(_inputs(0, false, 0, 0, 10_000)), FlowRisk.FLOOR_FEE);
    }

    function test_assemble_maxToxicityReachesCap() public pure {
        assertEq(FlowRisk.assembleFee(_inputs(0, false, 0, 10_000, 0)), FlowRisk.MAX_FEE);
    }

    /// @dev The core invariant: whatever the inputs, the quoted fee is a usable LP fee.
    function testFuzz_feeAlwaysWithinBounds(
        uint256 divergenceBps,
        bool closesGap,
        uint256 sizeBps,
        uint16 score,
        uint16 trust
    ) public pure {
        divergenceBps = bound(divergenceBps, 0, type(uint64).max);
        sizeBps = bound(sizeBps, 0, type(uint64).max);
        score = uint16(bound(score, 0, 10_000));
        trust = uint16(bound(trust, 0, 10_000));

        uint24 fee = FlowRisk.assembleFee(_inputs(divergenceBps, closesGap, sizeBps, score, trust));
        assertGe(fee, FlowRisk.FLOOR_FEE);
        assertLe(fee, FlowRisk.MAX_FEE);
    }

    /// @dev More toxicity never makes a swap cheaper, all else equal.
    function testFuzz_feeMonotonicInScore(uint16 a, uint16 b, uint256 sizeBps, uint16 trust) public pure {
        a = uint16(bound(a, 0, 10_000));
        b = uint16(bound(b, a, 10_000));
        sizeBps = bound(sizeBps, 0, 50_000);
        trust = uint16(bound(trust, 0, 10_000));

        assertLe(
            FlowRisk.assembleFee(_inputs(0, false, sizeBps, a, trust)),
            FlowRisk.assembleFee(_inputs(0, false, sizeBps, b, trust))
        );
    }

    /// @dev More trust never makes a swap more expensive, all else equal.
    function testFuzz_feeAntitonicInTrust(uint16 a, uint16 b, uint256 sizeBps, uint16 score) public pure {
        a = uint16(bound(a, 1, 10_000));
        b = uint16(bound(b, a, 10_000));
        sizeBps = bound(sizeBps, 0, 50_000);
        score = uint16(bound(score, 0, 10_000));

        assertGe(
            FlowRisk.assembleFee(_inputs(0, false, sizeBps, score, a)),
            FlowRisk.assembleFee(_inputs(0, false, sizeBps, score, b))
        );
    }

    /// @dev The property the whole redesign exists for: an attacker who rotates to a fresh
    ///      wallet does not reach the price an established benign trader pays. Rotation buys
    ///      "unproven", not "clean".
    function testFuzz_rotationNeverBeatsEarnedTrust(uint256 sizeBps) public pure {
        sizeBps = bound(sizeBps, FlowRisk.UNPROVEN_FREE_SIZE_BPS + 1, 50_000);

        uint24 freshWallet = FlowRisk.assembleFee(_inputs(0, false, sizeBps, 0, 0));
        uint24 provenWallet = FlowRisk.assembleFee(_inputs(0, false, sizeBps, 0, 10_000));

        assertGt(freshWallet, provenWallet);
    }

    /// @dev And the identity-free floor: however clean an identity looks, closing a large
    ///      oracle gap still costs, because L1 never consults reputation at all.
    function testFuzz_arbIsChargedRegardlessOfReputation(uint16 trust, uint256 divergenceBps) public pure {
        trust = uint16(bound(trust, 0, 10_000));
        divergenceBps = bound(divergenceBps, 500, 5_000);

        uint24 widening = FlowRisk.assembleFee(_inputs(divergenceBps, false, 0, 0, trust));
        uint24 closing = FlowRisk.assembleFee(_inputs(divergenceBps, true, 0, 0, trust));

        assertGt(closing, widening);
    }
}
