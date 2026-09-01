// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FlowRisk} from "../src/libraries/FlowRisk.sol";

/// @notice Exports the deployed fee arithmetic as a fixture the Python backtest is checked against.
/// @dev    `ai/backtest/fees.py` re-implements this library so a 30-day simulation can price
///         millions of swaps without an EVM in the loop. That mirror is only trustworthy if it
///         provably agrees with the Solidity, so this test writes every (input -> fee) pair it
///         sweeps to a CSV and `ai/tests/test_parity.py` asserts the mirror reproduces each row.
///         If the two ever drift, the Python test fails and the backtest's numbers are known to
///         be describing a model nobody shipped.
contract FlowRiskParityTest is Test {
    string internal constant OUT = "../ai/backtest/data/flowrisk-vectors.csv";

    function test_exportFeeVectors() public {
        uint256[10] memory divergences = [uint256(0), 10, 39, 40, 41, 50, 101, 500, 5_000, 20_000];
        uint256[5] memory sizes = [uint256(0), 50, 51, 500, 100_000];
        uint16[5] memory scores = [uint16(0), 1, 2_499, 7_500, 10_000];
        uint16[5] memory trusts = [uint16(0), 1, 5_000, 9_999, 10_000];

        vm.writeFile(OUT, "divergenceBps,closesGap,sizeBps,score,trust,fee\n");
        uint256 rows;

        for (uint256 a; a < divergences.length; ++a) {
            for (uint256 c; c < 2; ++c) {
                for (uint256 s; s < sizes.length; ++s) {
                    for (uint256 t; t < scores.length; ++t) {
                        for (uint256 u; u < trusts.length; ++u) {
                            FlowRisk.Inputs memory i = FlowRisk.Inputs({
                                divergenceBps: divergences[a],
                                closesGap: c == 1,
                                sizeBps: sizes[s],
                                score: scores[t],
                                trust: trusts[u]
                            });
                            uint24 fee = FlowRisk.assembleFee(i);

                            vm.writeLine(
                                OUT,
                                string.concat(
                                vm.toString(i.divergenceBps),
                                ",",
                                i.closesGap ? "1" : "0",
                                ",",
                                vm.toString(i.sizeBps),
                                ",",
                                vm.toString(uint256(i.score)),
                                ",",
                                vm.toString(uint256(i.trust)),
                                ",",
                                vm.toString(uint256(fee))
                                )
                            );
                            ++rows;
                        }
                    }
                }
            }
        }

        assertEq(rows, 10 * 2 * 5 * 5 * 5, "vector count");
    }
}
