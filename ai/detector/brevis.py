"""
brevis.py — read ZK-proven historical toxicity from the on-chain GlyphHistoryConsumer.

The Brevis App circuit (ai/brevis/circuit) proves the sum of a wallet's past
`ToxicTradeReported.localSeverity`. The Brevis network verifies that proof and calls
`GlyphHistoryConsumer.handleProofResult`, which stores `histToxScore[wallet]`. Here we
just read that value — a trustless, replay-proof feature the attestor can't fake.

Falls back to None (caller then uses the RPC event scan) when no consumer is configured
or no proof exists yet for the wallet.
"""

from __future__ import annotations

import os

from web3 import Web3
from dotenv import load_dotenv

load_dotenv()

_CONSUMER_ABI = [
    {
        "name": "histToxScore",
        "type": "function",
        "stateMutability": "view",
        "inputs": [{"name": "wallet", "type": "address"}],
        "outputs": [{"name": "", "type": "uint16"}],
    },
    {
        "name": "provenAt",
        "type": "function",
        "stateMutability": "view",
        "inputs": [{"name": "wallet", "type": "address"}],
        "outputs": [{"name": "", "type": "uint64"}],
    },
]


def extract_from_brevis(wallet: str) -> float | None:
    """Return ZK-proven historical toxicity normalised to [0, 1], or None if unavailable."""
    addr = os.environ.get("BREVIS_CONSUMER_ADDRESS", "")
    if not addr:
        return None

    rpc = os.environ.get("RPC_URL", "https://sepolia.unichain.org")
    try:
        w3 = Web3(Web3.HTTPProvider(rpc))
        consumer = w3.eth.contract(
            address=Web3.to_checksum_address(addr),
            abi=_CONSUMER_ABI,
        )
        raw = consumer.functions.histToxScore(Web3.to_checksum_address(wallet)).call()
        proven_at = consumer.functions.provenAt(Web3.to_checksum_address(wallet)).call()
        if int(proven_at) == 0:
            return None  # no proof submitted yet for this wallet
        return min(int(raw) / 10_000.0, 1.0)
    except Exception:
        return None
