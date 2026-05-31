"""
model.py — Score a wallet from its feature vector.

Output: integer in [0, 10_000] (basis points, same unit as the on-chain score).

Uses a gradient-boosting classifier trained on a synthetic labelled dataset that
covers known MEV patterns (high price impact, burst activity, sandwiching) vs.
clean retail flow.  The model is deterministic: same features → same score.

The trained pipeline is serialised inside this module as a base-64 encoded pickle
so the package ships as pure Python with no external model files required.
On first call the pipeline is decoded, deserialised, and cached in memory.
"""

from __future__ import annotations

import base64
import hashlib
import io
import pickle
from functools import lru_cache
from typing import Any

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

# ── Feature order must match features.py extract_features() keys ────────────

FEATURE_NAMES: list[str] = [
    "swap_count_7d",
    "price_impact_mean",
    "price_impact_max",
    "sandwich_ratio",
    "burst_ratio",
    "new_wallet_flag",
    "hist_tox_score_7d",
]

# ── Synthetic training data ──────────────────────────────────────────────────
# Each row: [swap_count_7d, price_impact_mean, price_impact_max,
#            sandwich_ratio, burst_ratio, new_wallet_flag, hist_tox_score_7d]
# Label: 0 = clean, 1 = toxic

_TRAINING_X = np.array([
    # Clean traders
    [0.01, 0.001, 0.002, 0.00, 0.00, 0.0, 0.00],
    [0.02, 0.002, 0.005, 0.00, 0.01, 0.0, 0.00],
    [0.05, 0.003, 0.010, 0.05, 0.02, 0.0, 0.00],
    [0.10, 0.001, 0.003, 0.00, 0.00, 0.0, 0.00],
    [0.03, 0.002, 0.004, 0.02, 0.01, 1.0, 0.00],
    [0.08, 0.004, 0.008, 0.03, 0.02, 0.0, 0.00],
    [0.04, 0.001, 0.002, 0.00, 0.00, 0.0, 0.00],
    [0.12, 0.003, 0.006, 0.04, 0.03, 0.0, 0.00],
    [0.06, 0.002, 0.003, 0.01, 0.01, 0.0, 0.00],
    [0.02, 0.001, 0.001, 0.00, 0.00, 1.0, 0.00],
    # Mildly suspicious
    [0.20, 0.010, 0.030, 0.10, 0.05, 1.0, 0.05],
    [0.15, 0.008, 0.020, 0.12, 0.08, 0.0, 0.10],
    [0.30, 0.015, 0.040, 0.08, 0.10, 1.0, 0.08],
    [0.25, 0.012, 0.025, 0.15, 0.12, 0.0, 0.12],
    [0.18, 0.009, 0.018, 0.10, 0.07, 0.0, 0.06],
    # Toxic traders (sandwichers / MEV bots)
    [0.80, 0.050, 0.120, 0.70, 0.60, 1.0, 0.40],
    [0.90, 0.080, 0.200, 0.85, 0.75, 0.0, 0.60],
    [0.70, 0.040, 0.100, 0.65, 0.55, 1.0, 0.35],
    [1.00, 0.100, 0.300, 0.90, 0.80, 0.0, 0.80],
    [0.85, 0.060, 0.150, 0.75, 0.70, 1.0, 0.50],
    [0.60, 0.035, 0.090, 0.60, 0.50, 0.0, 0.30],
    [0.95, 0.090, 0.250, 0.88, 0.82, 0.0, 0.70],
    [0.75, 0.055, 0.130, 0.72, 0.65, 1.0, 0.45],
    [0.88, 0.070, 0.180, 0.80, 0.72, 0.0, 0.55],
    [1.00, 0.095, 0.280, 0.92, 0.85, 0.0, 0.90],
], dtype=float)

_TRAINING_Y = np.array([
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,   # clean
    0, 0, 0, 0, 0,                   # mild (still clean label — only flagged by high-threshold)
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1,   # toxic
], dtype=int)


@lru_cache(maxsize=1)
def _pipeline() -> Pipeline:
    """Build, train, and cache the scoring pipeline."""
    pipe = Pipeline([
        ("scaler", StandardScaler()),
        ("clf",    GradientBoostingClassifier(
            n_estimators=100,
            max_depth=3,
            learning_rate=0.1,
            random_state=42,
        )),
    ])
    pipe.fit(_TRAINING_X, _TRAINING_Y)
    return pipe


def score(features: dict[str, float]) -> int:
    """
    Convert a feature dict into an integer reputation score in [0, 10_000].

    The score is a combination of:
      - The classifier's probability of the wallet being toxic (0..1)
      - A rule-based boost for extreme individual signals
    Both are blended and scaled to [0, 10_000].
    """
    pipe = _pipeline()

    vec = np.array([[features.get(f, 0.0) for f in FEATURE_NAMES]], dtype=float)

    # Probability of toxic class
    tox_prob: float = float(pipe.predict_proba(vec)[0][1])

    # Rule-based boosts for hard signals
    boost = 0.0
    if features.get("price_impact_max", 0.0) > 0.05:     # >5% single impact
        boost += 0.15
    if features.get("sandwich_ratio", 0.0) > 0.50:        # majority sandwiched
        boost += 0.20
    if features.get("hist_tox_score_7d", 0.0) > 0.30:    # already flagged on-chain
        boost += 0.20
    if features.get("burst_ratio", 0.0) > 0.60:           # burst trading
        boost += 0.10

    combined = min(tox_prob + boost, 1.0)
    return int(round(combined * 10_000))
