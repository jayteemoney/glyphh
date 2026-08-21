"""
features.py — Extract per-wallet on-chain features for the Glyph scoring model.

Features returned (all floats, normalised to [0, 1] unless stated):
  swap_count_7d       — number of swaps in the last LOOKBACK_BLOCKS blocks
  price_impact_mean   — mean |price impact| across those swaps (raw bps / 10_000)
  price_impact_max    — worst single price impact (raw bps / 10_000)
  sandwich_ratio      — fraction of swaps that appear sandwiched
  burst_ratio         — fraction of blocks where wallet made >1 swap (burstiness)
  new_wallet_flag     — 1.0 if first tx on-chain is within 7 days, else 0.0
  hist_tox_score_7d   — normalised sum of ToxicTradeReported.localSeverity / 10_000
"""

from __future__ import annotations

import os

from web3 import Web3
from web3.types import LogReceipt

from detector.brevis import extract_from_brevis
from dotenv import load_dotenv

load_dotenv()

_REGISTRY_ABI = [
    {
        "name": "trustDataOf",
        "type": "function",
        "inputs": [{"name": "wallet", "type": "address"}],
        "outputs": [
            {
                "name": "",
                "type": "tuple",
                "components": [
                    {"name": "value",     "type": "uint16"},
                    {"name": "updatedAt", "type": "uint64"},
                    {"name": "nonce",     "type": "uint32"},
                ],
            }
        ],
        "stateMutability": "view",
    },
    {
        "name": "scoreDataOf",
        "type": "function",
        "inputs": [{"name": "wallet", "type": "address"}],
        "outputs": [
            {
                "name": "",
                "type": "tuple",
                "components": [
                    {"name": "value",     "type": "uint16"},
                    {"name": "updatedAt", "type": "uint64"},
                    {"name": "nonce",     "type": "uint32"},
                ],
            }
        ],
        "stateMutability": "view",
    },
]

_TOXIC_TRADE_TOPIC = Web3.keccak(
    text="ToxicTradeReported(address,address,uint16,uint256)"
).hex()


def _w3() -> Web3:
    rpc = os.environ.get("RPC_URL", "https://sepolia.unichain.org")
    return Web3(Web3.HTTPProvider(rpc))


def _lookback() -> int:
    return int(os.environ.get("LOOKBACK_BLOCKS", "50400"))


def extract_features(wallet: str) -> dict[str, float]:
    """Return a feature dict for *wallet* by scanning recent on-chain data."""
    w3 = _w3()
    wallet_cs = Web3.to_checksum_address(wallet)

    latest     = w3.eth.block_number
    from_block = max(0, latest - _lookback())

    swap_events  = _fetch_swap_events(w3, wallet_cs, from_block, latest)
    toxic_events = _fetch_toxic_events(w3, wallet_cs, from_block, latest)

    swap_count        = len(swap_events)
    price_impacts     = [_parse_price_impact(e) for e in swap_events]
    price_impact_mean = (sum(price_impacts) / len(price_impacts)) / 10_000 if price_impacts else 0.0
    price_impact_max  = max(price_impacts) / 10_000 if price_impacts else 0.0
    sandwich_ratio    = _compute_sandwich_ratio(swap_events)
    burst_ratio       = _compute_burst_ratio(swap_events)
    new_wallet_flag   = _is_new_wallet(w3, wallet_cs, from_block)
    # Prefer the ZK-proven historical toxicity (trustless); fall back to the RPC event scan.
    brevis_score      = extract_from_brevis(wallet_cs)
    hist_tox_score_7d = brevis_score if brevis_score is not None else _compute_hist_tox(toxic_events)

    return {
        "swap_count_7d":     min(swap_count / 1000.0, 1.0),
        "price_impact_mean": price_impact_mean,
        "price_impact_max":  price_impact_max,
        "sandwich_ratio":    sandwich_ratio,
        "burst_ratio":       burst_ratio,
        "new_wallet_flag":   new_wallet_flag,
        "hist_tox_score_7d": hist_tox_score_7d,
    }


def fetch_current_nonce(wallet: str, trust: bool = False) -> int:
    """
    Read the current on-chain nonce for *wallet* from the registry.

    Score and trust keep independent nonce sequences, so the caller must say which one
    it is advancing. Reading the wrong one produces a signature the registry rejects
    with NonceTooLow -- which is the intended behaviour, since the separation is what
    stops a captured score attestation being replayed as trust.
    """
    registry_addr = os.environ.get("REGISTRY_ADDRESS", "")
    if not registry_addr:
        return 0

    w3 = _w3()
    registry = w3.eth.contract(
        address=Web3.to_checksum_address(registry_addr),
        abi=_REGISTRY_ABI,
    )
    fn = registry.functions.trustDataOf if trust else registry.functions.scoreDataOf
    data = fn(Web3.to_checksum_address(wallet)).call()
    return int(data[2])


def _fetch_swap_events(
    w3: Web3, wallet: str, from_block: int, to_block: int
) -> list[LogReceipt]:
    # Swap events live on the v4 PoolManager (the hook never emits Swap itself);
    # we scan them all and attribute each to the transaction's EOA sender.
    pm_addr = os.environ.get("POOL_MANAGER_ADDRESS", "")
    if not pm_addr:
        return []

    swap_topic = Web3.keccak(
        text="Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
    ).hex()

    try:
        logs = w3.eth.get_logs({
            "fromBlock": from_block,
            "toBlock":   to_block,
            "address":   Web3.to_checksum_address(pm_addr),
            "topics":    [swap_topic],
        })
        # Filter for transactions originating from our wallet
        filtered = []
        for log in logs:
            try:
                tx = w3.eth.get_transaction(log["transactionHash"])
                if tx["from"].lower() == wallet.lower():
                    filtered.append(log)
            except Exception:
                continue
        return filtered
    except Exception:
        return []


def _fetch_toxic_events(
    w3: Web3, wallet: str, from_block: int, to_block: int
) -> list[LogReceipt]:
    registry_addr = os.environ.get("REGISTRY_ADDRESS", "")
    if not registry_addr:
        return []

    try:
        logs = w3.eth.get_logs({
            "fromBlock": from_block,
            "toBlock":   to_block,
            "address":   Web3.to_checksum_address(registry_addr),
            "topics":    [
                _TOXIC_TRADE_TOPIC,
                "0x" + wallet[2:].lower().zfill(64),
            ],
        })
        return list(logs)
    except Exception:
        return []


def _parse_price_impact(log: LogReceipt) -> int:
    """Price impact is not directly in Swap logs; return 0 (hook handles it on-chain)."""
    return 0


def _compute_sandwich_ratio(events: list[LogReceipt]) -> float:
    if not events:
        return 0.0
    block_counts: dict[int, int] = {}
    for e in events:
        bn = e["blockNumber"]
        block_counts[bn] = block_counts.get(bn, 0) + 1
    sandwiched = sum(1 for e in events if block_counts[e["blockNumber"]] > 1)
    return sandwiched / len(events)


def _compute_burst_ratio(events: list[LogReceipt]) -> float:
    if not events:
        return 0.0
    block_counts: dict[int, int] = {}
    for e in events:
        bn = e["blockNumber"]
        block_counts[bn] = block_counts.get(bn, 0) + 1
    burst_blocks = sum(1 for c in block_counts.values() if c > 1)
    return burst_blocks / len(block_counts)


def _is_new_wallet(w3: Web3, wallet: str, from_block: int) -> float:
    try:
        count_now   = w3.eth.get_transaction_count(wallet)
        if count_now == 0:
            return 1.0
        count_start = w3.eth.get_transaction_count(wallet, from_block)
        return 1.0 if count_start == 0 else 0.0
    except Exception:
        return 0.0


def _compute_hist_tox(events: list[LogReceipt]) -> float:
    total = 0
    for e in events:
        try:
            data = e["data"]
            raw  = data if isinstance(data, (bytes, bytearray)) else bytes.fromhex(
                data[2:] if str(data).startswith("0x") else str(data)
            )
            if len(raw) >= 32:
                severity = int.from_bytes(raw[:32], "big") & 0xFFFF
                total += severity
        except Exception:
            continue
    return min(total / 10_000.0, 1.0)


# ── Trust features (v2) ──────────────────────────────────────────────────────

_FEE_QUOTED_TOPIC = Web3.keccak(
    text="FeeQuoted(bytes32,address,uint24,uint24,uint24,uint24,uint24,uint24)"
).hex()

_SANDWICH_TOPIC = Web3.keccak(
    text="SandwichDetected(bytes32,address,address,address,uint256)"
).hex()


def extract_trust_features_onchain(wallet: str) -> dict[str, int]:
    """
    Raw counts for the trust model, read from the hook's own event stream.

    The interesting one is `uninformed_swaps`. Trust is earned by supplying the order
    flow LPs actually want — flow that moves the pool *away* from the reference price
    rather than closing the gap. Establishing that offline would normally mean replaying
    historical oracle prices against every swap, which is slow and approximate.

    It is unnecessary here, because the hook already decided at execution time and put
    the answer on-chain: `FeeQuoted.arb` is non-zero exactly when the swap was
    gap-closing. Counting swaps whose arb premium was zero is therefore an exact record
    of uninformed flow, not an estimate of it — and it costs one log scan.
    """
    w3 = _w3()
    wallet_cs = Web3.to_checksum_address(wallet)
    hook_addr = os.environ.get("HOOK_ADDRESS", "")

    latest = w3.eth.block_number
    from_block = max(0, latest - _lookback())

    total_swaps = 0
    uninformed_swaps = 0
    clean_streak = 0
    sandwich_legs = 0

    if hook_addr:
        wallet_topic = "0x" + wallet_cs[2:].rjust(64, "0").lower()
        hook_cs = Web3.to_checksum_address(hook_addr)

        try:
            quotes = w3.eth.get_logs({
                "fromBlock": from_block,
                "toBlock":   latest,
                "address":   hook_cs,
                "topics":    [_FEE_QUOTED_TOPIC, None, wallet_topic],
            })
        except Exception:
            quotes = []

        for log in quotes:
            data = bytes(log["data"])
            # base, arb, unproven, toxic, trustDiscount, finalFee — six words of 32 bytes.
            if len(data) < 192:
                continue
            arb = int.from_bytes(data[32:64], "big")
            total_swaps += 1
            if arb == 0:
                uninformed_swaps += 1
                clean_streak += 1
            else:
                clean_streak = 0

        try:
            sandwiches = w3.eth.get_logs({
                "fromBlock": from_block,
                "toBlock":   latest,
                "address":   hook_cs,
                "topics":    [_SANDWICH_TOPIC, None, wallet_topic],
            })
            sandwich_legs = len(sandwiches)
        except Exception:
            sandwich_legs = 0

    settled_volume_wei = _settled_volume(w3, wallet_cs, from_block, latest)
    wallet_age_blocks = _wallet_age_blocks(w3, wallet_cs, from_block, latest)

    return {
        "settled_volume_wei": settled_volume_wei,
        "wallet_age_blocks":  wallet_age_blocks,
        "uninformed_swaps":   uninformed_swaps,
        "total_swaps":        total_swaps,
        "clean_streak_swaps": clean_streak,
        "sandwich_legs":      sandwich_legs,
    }


def _settled_volume(w3: Web3, wallet: str, from_block: int, to_block: int) -> int:
    """Cumulative absolute notional across the wallet's swaps, in wei of token0."""
    total = 0
    for event in _fetch_swap_events(w3, wallet, from_block, to_block):
        data = bytes(event["data"])
        if len(data) < 64:
            continue
        amount0 = int.from_bytes(data[0:32], "big", signed=True)
        total += abs(amount0)
    return total


def _wallet_age_blocks(w3: Web3, wallet: str, from_block: int, to_block: int) -> int:
    """Blocks since the wallet's first observed swap in the lookback window."""
    events = _fetch_swap_events(w3, wallet, from_block, to_block)
    if not events:
        return 0
    first = min(int(e["blockNumber"]) for e in events)
    return max(0, to_block - first)
