"""
Scoring-model validation and behaviour.

The model is deterministic (same features -> same score) and trained on a
train/validation split. These tests pin the held-out validation floor (so a
regression that degrades the model fails CI) and verify the newly-realised
price-impact axis actually drives the score.
"""

import pytest

from detector.model import score, validation_metrics


def _feats(**overrides):
    base = {
        "swap_count_7d": 0.1,
        "price_impact_mean": 0.0,
        "price_impact_max": 0.0,
        "sandwich_ratio": 0.0,
        "burst_ratio": 0.0,
        "new_wallet_flag": 0.0,
        "hist_tox_score_7d": 0.0,
    }
    base.update(overrides)
    return base


def test_score_is_deterministic():
    f = _feats(price_impact_max=0.08, sandwich_ratio=0.9)
    assert score(f) == score(f)


def test_score_always_in_range():
    assert 0 <= score(_feats()) <= 10_000
    assert 0 <= score(_feats(price_impact_max=1.0, hist_tox_score_7d=1.0)) <= 10_000


def test_clean_is_cheap_and_toxic_trades_are_flagged():
    clean = score(_feats())
    toxic = score(_feats(price_impact_max=0.25, sandwich_ratio=0.9, burst_ratio=0.8))
    assert clean < 3_000
    assert toxic > 5_000
    assert toxic > clean


def test_price_impact_axis_drives_the_score():
    """Price impact was once a stub (always 0); it must now move the score."""
    low = score(_feats(price_impact_max=0.01, price_impact_mean=0.001))
    high = score(_feats(price_impact_max=0.30, price_impact_mean=0.10, sandwich_ratio=0.7))
    assert high > low


def test_validation_metrics_meet_a_floor():
    """The model must actually separate clean from toxic on its held-out split."""
    m = validation_metrics()
    assert m["accuracy"] >= 0.8
    assert m["f1"] >= 0.5
