"""
trust.py — Score a wallet's *earned trust*: the claim that buys its fee down.

Glyph v1 could only ever make a swap more expensive, which is what made it
sybillable: the clean state was the default, so it was free, and rotating to a
fresh EOA reset the game. v2 charges unproven identities and discounts proven
ones, so rotation forfeits something instead of escaping something.

That inversion only works if "proven" is expensive to reach. Trust is therefore
scored on evidence that *takes time and real volume to accumulate* and that an
attacker cannot manufacture cheaply:

  settled_volume      — cumulative swap notional, log-scaled. Costs fees to fake.
  wallet_age          — blocks since first activity. Cannot be bought, only waited.
  uninformed_ratio    — share of swaps that moved the pool *away* from the oracle.
                        This is the strongest signal available: informed flow closes
                        the gap, uninformed flow widens it, and only the latter is
                        the order flow LPs actually want. It is also the one an
                        attacker cannot fake without simply trading unprofitably.
  clean_streak        — swaps since the last toxic report, capped.
  no_sandwich_legs    — 1.0 if the wallet has never been a sandwich attacker.

Deliberately NOT a machine-learning model. A gradient-boosted classifier is a
reasonable way to flag anomalies, because a false positive there costs a trader
one expensive swap. Trust is the opposite: a false positive hands a discount to
an attacker, so the rule has to be legible, auditable, and boring. Every term
below is something a trader can read and verify about their own history.
"""

from __future__ import annotations

import math

# Trust is not a weighted sum. It is depth *multiplied by* quality, because those two
# are not substitutes and an additive model lets one buy the other.
#
# A first pass here did use a flat weighted sum, and sanity-checking it caught two errors
# worth recording. A wallet with no history at all scored 500, because "has never been a
# sandwich attacker" was true of a wallet that had never traded -- absence of evidence
# counting as evidence, which is exactly the hole the inversion is meant to close. And an
# arbitrageur whose flow was 95% gap-closing still scored 5818, because volume and age
# carried it. Under a product, neither can happen: no history means depth 0, and informed
# flow means quality ~0.
_DEPTH_WEIGHTS: dict[str, float] = {
    "settled_volume": 0.40,
    "wallet_age": 0.30,
    "clean_streak": 0.30,
}

MAX_TRUST = 10_000

# Below this many swaps a wallet has not demonstrated anything either way. Three good
# trades is not a record, and making it cheap to look proven would defeat the point.
MIN_SWAPS_FOR_TRUST = 10

# A wallet with any toxicity at all earns no trust. The two axes are independent
# on-chain, but a wallet cannot be simultaneously under suspicion and proven.
TOXIC_TRUST_CUTOFF = 500


def normalise_volume(total_notional_wei: int) -> float:
    """Log-scale settled volume into [0, 1]; ~1000 ETH of settled flow saturates."""
    if total_notional_wei <= 0:
        return 0.0
    eth = total_notional_wei / 1e18
    return min(math.log10(1.0 + eth) / 3.0, 1.0)


def normalise_age(age_blocks: int) -> float:
    """Blocks since first activity into [0, 1]; ~30 days on a 1s chain saturates."""
    if age_blocks <= 0:
        return 0.0
    return min(age_blocks / 2_592_000.0, 1.0)


def normalise_streak(clean_swaps: int) -> float:
    """Swaps since the last toxic report into [0, 1]; 100 clean swaps saturates."""
    if clean_swaps <= 0:
        return 0.0
    return min(clean_swaps / 100.0, 1.0)


def score_trust(features: dict[str, float], current_toxicity: int = 0) -> int:
    """
    Combine trust features into a 0..10_000 score.

    trust = depth x quality x integrity

      depth     how much settled history exists (volume, age, clean streak)
      quality   what share of that history was uninformed flow
      integrity zero if the wallet has ever been a sandwich attacker

    `current_toxicity` is the wallet's live on-chain score. Any meaningful toxicity
    zeroes trust outright rather than merely offsetting it — a wallet under active
    suspicion should pay the unproven price, not a discounted one.
    """
    if current_toxicity >= TOXIC_TRUST_CUTOFF:
        return 0
    if features.get("integrity", 1.0) <= 0.0:
        return 0
    if not features.get("has_min_history", False):
        return 0

    depth = 0.0
    for name, weight in _DEPTH_WEIGHTS.items():
        depth += weight * _clamp01(features.get(name, 0.0))

    quality = _clamp01(features.get("uninformed_ratio", 0.0))
    return int(round(_clamp01(depth * quality) * MAX_TRUST))


def extract_trust_features(
    *,
    settled_volume_wei: int,
    wallet_age_blocks: int,
    uninformed_swaps: int,
    total_swaps: int,
    clean_streak_swaps: int,
    sandwich_legs: int,
) -> dict[str, float]:
    """Build the trust feature vector from raw on-chain counts."""
    return {
        "settled_volume": normalise_volume(settled_volume_wei),
        "wallet_age": normalise_age(wallet_age_blocks),
        # A wallet with no history is unproven, not trusted. Absence of evidence
        # scores zero here, never a default of "probably fine".
        "uninformed_ratio": (uninformed_swaps / total_swaps) if total_swaps > 0 else 0.0,
        "clean_streak": normalise_streak(clean_streak_swaps),
        "integrity": 0.0 if sandwich_legs > 0 else 1.0,
        "has_min_history": total_swaps >= MIN_SWAPS_FOR_TRUST,
    }


def explain(features: dict[str, float], trust: int) -> str:
    """Human-readable breakdown, for `run.py --verbose` and for the dashboard."""
    depth = sum(w * _clamp01(features.get(n, 0.0)) for n, w in _DEPTH_WEIGHTS.items())
    quality = _clamp01(features.get("uninformed_ratio", 0.0))

    lines = [f"trust = {trust}/{MAX_TRUST}   (depth {depth:.3f} x quality {quality:.3f})"]
    for name, weight in _DEPTH_WEIGHTS.items():
        value = _clamp01(features.get(name, 0.0))
        lines.append(f"  depth: {name:<16} {value:>6.3f} x {weight:>4.2f}")
    lines.append(f"  quality: uninformed_ratio {quality:>6.3f}")
    if not features.get("has_min_history", False):
        lines.append(f"  gated:  fewer than {MIN_SWAPS_FOR_TRUST} swaps -> trust 0")
    if features.get("integrity", 1.0) <= 0.0:
        lines.append("  gated:  sandwich leg on record -> trust 0")
    return "\n".join(lines)


def _clamp01(x: float) -> float:
    return 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)
