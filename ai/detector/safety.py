"""
safety.py — client-side replay + rate-limit guards for the attestor key.

On-chain the registry already enforces strictly-monotonic nonces, but a careless
operator could still sign the same (wallet, nonce) twice before the chain updates, or
hammer the key. These guards make double-signing and bursts impossible from the client.

State is a tiny JSON file (path via DETECTOR_STATE); no secrets are ever written.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

_STATE_PATH = Path(os.environ.get("DETECTOR_STATE", ".detector_state.json"))
_MIN_INTERVAL = float(os.environ.get("MIN_SIGN_INTERVAL", "1.0"))


def _load() -> dict:
    if _STATE_PATH.exists():
        try:
            return json.loads(_STATE_PATH.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def _save(state: dict) -> None:
    _STATE_PATH.write_text(json.dumps(state))


def check_and_record(wallet: str, nonce: int) -> None:
    """Raise ValueError if (wallet, nonce) was already signed or if rate-limited; else record it."""
    state = _load()
    key = wallet.lower()
    entry = state.get(key, {})
    last_nonce = int(entry.get("nonce", 0))
    last_time = float(entry.get("time", 0.0))
    now = time.time()

    if nonce <= last_nonce:
        raise ValueError(f"replay guard: nonce {nonce} <= last signed {last_nonce} for {wallet}")

    elapsed = now - last_time
    if elapsed < _MIN_INTERVAL:
        raise ValueError(f"rate limit: wait {_MIN_INTERVAL - elapsed:.2f}s before re-signing {wallet}")

    state[key] = {"nonce": nonce, "time": now}
    _save(state)
