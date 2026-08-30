"""
model.py — Score a wallet from its feature vector.

Output: integer in [0, 10_000] (basis points, same unit as the on-chain score).

Uses a gradient-boosting classifier trained on a labelled dataset that
covers known MEV patterns (high price impact, burst activity, sandwiching) vs.
clean retail flow.  The model is deterministic: same features → same score.
For the shipped detector the labels are a curated synthetic set (the package
ships as pure Python with no external model files), but training is a real,
deterministic train/validation split and `validation_metrics()` reports the
held-out scores — anything that degrades the model fails CI.

The training data is embedded in this module, so the package ships as pure Python
with no external model files required. The pipeline is trained (and cached) on
first call, deterministically — same features always yield the same score.
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
from sklearn.model_selection import train_test_split
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
    """Build, train (train/validation split), and cache the scoring pipeline.

    The training set is small and synthetic because the package must ship as pure
    Python with no external artifacts, but it is *validated*, not eyeballed:
    the classifier is fit on a deterministic 80/20 train/validation split and
    `validation_metrics()` reports held-out accuracy + F1 the tests assert against
    a fixed floor, so a regression that degrades the model fails CI.
    """
    clf = GradientBoostingClassifier(
        n_estimators=100,
        max_depth=3,
        learning_rate=0.1,
        random_state=42,
    )

    # Deterministic stratified split: seed fixed so metrics are reproducible and
    # the same split is used for fitting and for validation every run.
    split = train_test_split(
        _TRAINING_X, _TRAINING_Y,
        test_size=0.2,
        random_state=7,
        stratify=_TRAINING_Y,
    )
    X_tr, X_va, y_tr, y_va = split

    scaler = StandardScaler().fit(X_tr)
    X_tr_s = scaler.transform(X_tr)

    clf.fit(X_tr_s, y_tr)

    pipe = Pipeline([("scaler", scaler), ("clf", clf)])
    _cache_validation(pipe, X_va, y_va)
    return pipe


def validation_metrics() -> dict[str, float]:
    """Held-out accuracy / F1 computed on the validation split of the training set."""
    pipe = _pipeline()
    acc = float(_VALIDATION.get("accuracy", 0.0))
    f1 = float(_VALIDATION.get("f1", 0.0))
    return {"accuracy": acc, "f1": f1}


_VALIDATION: dict[str, float] = {}


def _cache_validation(pipe: Pipeline, X_va: np.ndarray, y_va: np.ndarray) -> None:
    from sklearn.metrics import accuracy_score, f1_score

    pred = pipe.predict(X_va)
    _VALIDATION["accuracy"] = float(accuracy_score(y_va, pred))
    _VALIDATION["f1"] = float(f1_score(y_va, pred, zero_division=0))


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
