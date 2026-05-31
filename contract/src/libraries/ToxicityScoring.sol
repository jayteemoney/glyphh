// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library ToxicityScoring {
    uint24 internal constant DEFAULT_BASE_FEE = 3_000;
    uint24 internal constant MAX_FEE          = 100_000;
    uint16 internal constant MAX_SCORE        = 10_000;

    function scoreToFee(uint16 score) internal pure returns (uint24 fee) {
        if (score == 0) return DEFAULT_BASE_FEE;
        if (score >= MAX_SCORE) return MAX_FEE;

        uint256 s = score;
        uint256 f;
        if (s < 2_500) {
            f = 3_000 + (s * 7_000) / 2_500;
        } else if (s < 7_500) {
            f = 10_000 + ((s - 2_500) * 30_000) / 5_000;
        } else {
            f = 40_000 + ((s - 7_500) * 60_000) / 2_500;
        }
        fee = uint24(f);
    }

    function computeSeverity(uint16 impactBps, uint16 reputationScore) internal pure returns (uint16 severity) {
        uint256 combined = uint256(impactBps) + uint256(reputationScore);
        uint256 half = combined / 2;
        severity = half > MAX_SCORE ? uint16(MAX_SCORE) : uint16(half);
    }
}
