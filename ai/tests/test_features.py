"""
Real on-chain price-impact feature extraction.

The price-impact features (mean / max) exist in the model and in the feature
pipeline, but were stubbed to zero in both the general detector and the keeper,
which meant a whole axis of MEV signal was dead in every real path. These tests
assert the impact is now computed from genuine chain data (the pool's post-swap
`sqrtPriceX96` from the v4 Swap event), not a constant.
"""

import pytest

from detector.features import _batch_price_impacts, _sqrt_price_after, _deviation_bps


def _swap_log(sqrt_price_x96: int, block: int = 1) -> dict:
    """Build a minimally-shaped Swap-log dict with a real post-swap sqrt price."""
    data = b"\x00" * 64 + sqrt_price_x96.to_bytes(32, "big")  # word 0 = amount0, word 2 = price
    return {
        "blockNumber": block,
        "transactionHash": b"\x01" * 32,
        "data": "0x" + data.hex(),
    }


# ── Q64.96 helpers: sqrt price for a given price (price = sqrt^2 / 2^192) ────

def _sqrt_price_for(price: float) -> int:
    """sqrt(price) as Q64.96, for a plain (non-squared) price ~1.0."""
    return int(round((price ** 0.5) * (1 << 96)))


def test_sqrt_price_after_parses_word_2():
    p = _sqrt_price_for(1.0)
    assert _sqrt_price_after(_swap_log(p)) == p


def test_sqrt_price_after_handles_short_data():
    assert _sqrt_price_after({"data": b"\x01"}) is None


def test_deviation_bps_measures_price_move():
    # sqrt price for price 1.0 vs 1.01 -> ~100 bps move in *price*
    before = _sqrt_price_for(1.0)
    after = _sqrt_price_for(1.01)
    bps = _deviation_bps(before, after)
    assert 90 <= bps <= 110
    # symmetric up to rounding (1.0->1.01 is +1.0%, 1.01->1.0 is ~0.99%)
    assert _deviation_bps(after, before) == pytest.approx(bps, abs=2)


def test_batch_price_impacts_is_real_not_zero():
    # Two swaps: pool moves 1.0 -> 1.01 across them.
    logs = [
        _swap_log(_sqrt_price_for(1.0), block=1),
        _swap_log(_sqrt_price_for(1.01), block=1),
    ]
    impacts = _batch_price_impacts(logs)
    # first swap (no predecessor) contributes 0; second measures the real move.
    assert impacts[0] == 0
    assert 90 <= impacts[1] <= 110


def test_batch_price_impacts_ignores_flat_pool():
    logs = [
        _swap_log(_sqrt_price_for(1.0)),
        _swap_log(_sqrt_price_for(1.0)),
        _swap_log(_sqrt_price_for(1.0)),
    ]
    impacts = _batch_price_impacts(logs)
    assert impacts == [0, 0, 0]


def test_batch_price_impacts_cumulative_move_accumulates():
    logs = [
        _swap_log(_sqrt_price_for(1.0)),
        _swap_log(_sqrt_price_for(1.02)),  # +200 bps from step 1
        _swap_log(_sqrt_price_for(1.0)),   # -196 bps from step 2
    ]
    impacts = _batch_price_impacts(logs)
    assert impacts[0] == 0
    assert 190 <= impacts[1] <= 210
    assert 190 <= abs(impacts[2]) <= 210


# ── Keeper perspective ────────────────────────────────────────────────────────

def test_keeper_window_price_impact_is_real():
    from detector.keeper import SwapObs, window_features

    t = 1000.0
    swaps = [
        SwapObs(timestamp=t + 0, zero_for_one=True, fee=3000, sqrt_price=_sqrt_price_for(1.0)),
        SwapObs(timestamp=t + 1, zero_for_one=True, fee=3000, sqrt_price=_sqrt_price_for(1.01)),
        SwapObs(timestamp=t + 2, zero_for_one=True, fee=3000, sqrt_price=_sqrt_price_for(1.02)),
    ]
    feats = window_features(swaps, burst_gap=30.0)
    # impact mean should be positive and roughly in the few-hundred-bps range, not zero.
    assert feats["price_impact_max"] > 0.005  # > 50 bps
    assert feats["price_impact_mean"] > 0.005
    assert 0.0 <= feats["price_impact_max"] <= 1.0


def test_keeper_window_single_swap_has_no_impact():
    from detector.keeper import SwapObs, window_features

    swaps = [SwapObs(timestamp=0.0, zero_for_one=True, fee=3000, sqrt_price=_sqrt_price_for(1.0))]
    feats = window_features(swaps, burst_gap=30.0)
    assert feats["price_impact_mean"] == 0.0
    assert feats["price_impact_max"] == 0.0


def test_keeper_window_empty_is_zeroed():
    from detector.keeper import window_features

    feats = window_features([], burst_gap=30.0)
    assert feats["price_impact_mean"] == 0.0
    assert feats["price_impact_max"] == 0.0
    assert feats["swap_count_7d"] == 0.0
