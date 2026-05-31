// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ToxicityScoring} from "../src/libraries/ToxicityScoring.sol";

contract ToxicityScoringTest is Test {
    function test_scoreZeroReturnsBaseFee() public pure {
        assertEq(ToxicityScoring.scoreToFee(0), 3_000);
    }

    function test_maxScoreReturnsMaxFee() public pure {
        assertEq(ToxicityScoring.scoreToFee(10_000), 100_000);
    }

    function test_feeNeverBelowBaseFee(uint16 score) public pure {
        assertGe(ToxicityScoring.scoreToFee(score), 3_000);
    }

    function test_feeNeverExceedsMaxFee(uint16 score) public pure {
        assertLe(ToxicityScoring.scoreToFee(score), 100_000);
    }

    function test_feeMonotonicallyIncreasing(uint16 a, uint16 b) public pure {
        vm.assume(a <= b);
        assertLe(ToxicityScoring.scoreToFee(a), ToxicityScoring.scoreToFee(b));
    }

    function test_midpointFeeInRange() public pure {
        uint24 fee = ToxicityScoring.scoreToFee(5_000);
        assertGe(fee, 3_000);
        assertLe(fee, 100_000);
    }

    function test_severityBoundedByMaxScore(uint16 impact, uint16 score) public pure {
        assertLe(ToxicityScoring.computeSeverity(impact, score), 10_000);
    }

    function test_severityZeroInputsGiveZero() public pure {
        assertEq(ToxicityScoring.computeSeverity(0, 0), 0);
    }

    function test_severityMaxInputsGiveMax() public pure {
        assertEq(ToxicityScoring.computeSeverity(10_000, 10_000), 10_000);
    }
}
