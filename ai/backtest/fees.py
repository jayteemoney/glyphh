"""A Python mirror of `contract/src/libraries/FlowRisk.sol`.

The backtest must price swaps with *exactly* the arithmetic that is deployed, or its
numbers describe a model nobody shipped. Rather than ask the reader to trust that this
file matches, `contract/test/FlowRiskParity.t.sol` writes a grid of
(inputs -> fee) vectors straight out of the Solidity, and `ai/tests/test_parity.py`
asserts every row against the functions below. If they ever drift, that test fails.

All fees are in v4 pip units: 1_000_000 == 100%.
"""

from __future__ import annotations

from dataclasses import dataclass

FLOOR_FEE = 500  # 0.05%
BASE_FEE = 3_000  # 0.30%
MAX_FEE = 100_000  # 10.00%
MAX_SCORE = 10_000

ARB_TOLERANCE_BPS = 40
ARB_CAPTURE_PCT = 60
ARB_PREMIUM_CAP = 50_000

UNPROVEN_FREE_SIZE_BPS = 50
UNPROVEN_SLOPE = 40
UNPROVEN_CAP = 20_000


def arb_premium(divergence_bps: int, closes_gap: bool) -> int:
    if not closes_gap:
        return 0
    if divergence_bps <= ARB_TOLERANCE_BPS:
        return 0
    raw = (divergence_bps - ARB_TOLERANCE_BPS) * ARB_CAPTURE_PCT
    return min(raw, ARB_PREMIUM_CAP)


def unproven_premium(size_bps: int) -> int:
    if size_bps <= UNPROVEN_FREE_SIZE_BPS:
        return 0
    raw = (size_bps - UNPROVEN_FREE_SIZE_BPS) * UNPROVEN_SLOPE
    return min(raw, UNPROVEN_CAP)


def toxic_premium(score: int) -> int:
    if score == 0:
        return 0
    if score >= MAX_SCORE:
        return MAX_FEE - BASE_FEE
    if score < 2_500:
        f = 3_000 + (score * 7_000) // 2_500
    elif score < 7_500:
        f = 10_000 + ((score - 2_500) * 30_000) // 5_000
    else:
        f = 40_000 + ((score - 7_500) * 60_000) // 2_500
    return f - BASE_FEE


def trust_discount(trust: int) -> int:
    if trust == 0:
        return 0
    if trust >= MAX_SCORE:
        return BASE_FEE - FLOOR_FEE
    return (trust * (BASE_FEE - FLOOR_FEE)) // MAX_SCORE


@dataclass(frozen=True)
class Inputs:
    divergence_bps: int = 0
    closes_gap: bool = False
    size_bps: int = 0
    score: int = 0
    trust: int = 0


def assemble_fee(i: Inputs) -> int:
    f = BASE_FEE
    f += arb_premium(i.divergence_bps, i.closes_gap)
    if i.trust == 0:
        f += unproven_premium(i.size_bps)
    f += toxic_premium(i.score)

    d = trust_discount(i.trust)
    f = f - d if f > d else FLOOR_FEE

    if f < FLOOR_FEE:
        return FLOOR_FEE
    if f > MAX_FEE:
        return MAX_FEE
    return f
