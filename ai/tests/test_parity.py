"""The Python fee model must agree with the deployed Solidity, exactly, on every row.

`contract/test/FlowRiskParity.t.sol` sweeps a grid across every branch of
`FlowRisk.assembleFee` — both sides of the direction test, the arbitrage tolerance
boundary, the unproven free-size boundary, all three segments of the toxicity curve, and
the trust discount's floor clamp — and writes the results to CSV straight out of the EVM.

This test recomputes each row with `ai/backtest/fees.py`. If the mirror ever drifts from
the contract, the backtest in `docs/BACKTEST.md` is describing a model nobody shipped, and
this fails loudly rather than letting the numbers quietly go wrong.
"""

from __future__ import annotations

import csv
from pathlib import Path

import pytest

from backtest.fees import ARB_TOLERANCE_BPS, Inputs, assemble_fee

VECTORS = Path(__file__).resolve().parents[1] / "backtest" / "data" / "flowrisk-vectors.csv"


def _rows():
    if not VECTORS.exists():
        pytest.skip(
            f"{VECTORS.name} not found — regenerate with "
            "`forge test --match-contract FlowRiskParity` in contract/"
        )
    with VECTORS.open() as fh:
        return list(csv.DictReader(fh))


def test_vectors_exist_and_are_complete():
    rows = _rows()
    assert len(rows) == 10 * 2 * 5 * 5 * 5, "grid is incomplete; re-export from Solidity"


def test_python_mirror_matches_solidity_exactly():
    mismatches = []
    for r in _rows():
        i = Inputs(
            divergence_bps=int(r["divergenceBps"]),
            closes_gap=r["closesGap"] == "1",
            size_bps=int(r["sizeBps"]),
            score=int(r["score"]),
            trust=int(r["trust"]),
        )
        got, want = assemble_fee(i), int(r["fee"])
        if got != want:
            mismatches.append((i, got, want))

    assert not mismatches, "\n".join(
        f"{i} -> python {got}, solidity {want}" for i, got, want in mismatches[:10]
    )


def test_the_grid_actually_exercises_the_direction_test():
    """A parity grid that never separated the two directions would pass while proving nothing.

    Compare matched pairs — identical in every input but `closesGap` — and require that
    above the tolerance the gap-closing swap is strictly more expensive, and at or below it
    the two are identical. The boundary is read from the model so this cannot drift.
    """
    rows = _rows()
    keyed = {
        (r["divergenceBps"], r["sizeBps"], r["score"], r["trust"], r["closesGap"]): int(r["fee"])
        for r in rows
    }

    strictly_dearer = same = 0
    for (div, size, score, trust, closes), fee in keyed.items():
        if closes != "1":
            continue
        widening = keyed[(div, size, score, trust, "0")]
        if int(div) > ARB_TOLERANCE_BPS and fee < 100_000:
            assert fee > widening, f"divergence {div} bps: closing {fee} !> widening {widening}"
            strictly_dearer += 1
        elif int(div) <= ARB_TOLERANCE_BPS:
            assert fee == widening, f"within tolerance, {fee} != {widening}"
            same += 1

    assert strictly_dearer > 0, "no pair exercised the premium"
    assert same > 0, "no pair exercised the tolerance band"
