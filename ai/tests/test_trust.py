"""
Trust scoring behaviour.

These are the cases that decide whether the sybil inversion actually holds. A trust
model that hands a discount to a fresh wallet or an arbitrageur does not merely score
badly — it reopens exactly the hole the UHI9 judge identified, because rotating a
wallet would once again cost the attacker nothing.

Two of these tests exist because the first implementation failed them: a flat weighted
sum gave a wallet with no history 500 trust (never-sandwiched was true of a wallet that
had never traded), and gave a 95%-gap-closing arbitrageur 5818 (volume and age carried
it). Trust is now depth multiplied by quality, so neither can buy the other.
"""

import pytest

from detector.trust import (
    MAX_TRUST,
    MIN_SWAPS_FOR_TRUST,
    extract_trust_features,
    normalise_age,
    normalise_streak,
    normalise_volume,
    score_trust,
)


def _features(**overrides):
    base = dict(
        settled_volume_wei=500 * 10**18,
        wallet_age_blocks=2_000_000,
        uninformed_swaps=90,
        total_swaps=100,
        clean_streak_swaps=90,
        sandwich_legs=0,
    )
    base.update(overrides)
    return extract_trust_features(**base)


# ── The sybil property ───────────────────────────────────────────────────────

def test_fresh_wallet_earns_no_trust():
    """The whole inversion rests on this: rotating buys 'unproven', never 'clean'."""
    f = extract_trust_features(
        settled_volume_wei=0,
        wallet_age_blocks=0,
        uninformed_swaps=0,
        total_swaps=0,
        clean_streak_swaps=0,
        sandwich_legs=0,
    )
    assert score_trust(f) == 0


def test_thin_history_is_gated():
    """A handful of good trades is not a record."""
    f = _features(total_swaps=MIN_SWAPS_FOR_TRUST - 1, uninformed_swaps=MIN_SWAPS_FOR_TRUST - 1)
    assert score_trust(f) == 0


def test_established_benign_trader_earns_most_of_the_discount():
    assert score_trust(_features()) > 7_000


# ── Quality gates depth ──────────────────────────────────────────────────────

def test_arbitrageur_earns_almost_nothing_despite_volume_and_age():
    """Informed flow is what Glyph charges for. Volume must not buy it a discount."""
    arb = score_trust(_features(uninformed_swaps=5))
    benign = score_trust(_features(uninformed_swaps=90))
    assert arb < 1_000
    assert benign > 7 * arb


def test_volume_cannot_substitute_for_quality():
    huge_volume_informed = score_trust(_features(settled_volume_wei=10**24, uninformed_swaps=0))
    assert huge_volume_informed == 0


def test_quality_cannot_substitute_for_depth():
    perfect_quality_no_depth = score_trust(
        _features(settled_volume_wei=0, wallet_age_blocks=0, clean_streak_swaps=0, uninformed_swaps=100)
    )
    assert perfect_quality_no_depth < 1_000


# ── Hard zeroes ──────────────────────────────────────────────────────────────

def test_sandwich_leg_zeroes_trust_permanently():
    assert score_trust(_features(sandwich_legs=1)) == 0


def test_live_toxicity_zeroes_trust():
    """A wallet under active suspicion pays the unproven price, not a discounted one."""
    f = _features()
    assert score_trust(f) > 0
    assert score_trust(f, current_toxicity=4_000) == 0


# ── Monotonicity and bounds ──────────────────────────────────────────────────

@pytest.mark.parametrize("uninformed", [0, 10, 25, 50, 75, 100])
def test_trust_is_monotonic_in_quality(uninformed):
    lower = score_trust(_features(uninformed_swaps=uninformed))
    higher = score_trust(_features(uninformed_swaps=min(uninformed + 10, 100)))
    assert higher >= lower


@pytest.mark.parametrize(
    "volume,age,uninformed",
    [(0, 0, 0), (10**30, 10**9, 100), (10**18, 1, 50), (0, 10**9, 100)],
)
def test_trust_always_within_bounds(volume, age, uninformed):
    f = _features(settled_volume_wei=volume, wallet_age_blocks=age, uninformed_swaps=uninformed)
    assert 0 <= score_trust(f) <= MAX_TRUST


def test_normalisers_are_bounded():
    for fn, big in ((normalise_volume, 10**30), (normalise_age, 10**12), (normalise_streak, 10**9)):
        assert 0.0 <= fn(0) <= 1.0
        assert fn(big) == 1.0
        assert fn(-1) == 0.0
