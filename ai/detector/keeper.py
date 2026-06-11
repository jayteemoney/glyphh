"""
keeper.py — autonomous scoring loop for the Glyph detector (HANDOFF §6 Phase 2).

Watches the Uniswap v4 PoolManager for Swap events in the Glyph pool, attributes
each swap to the EOA that sent the transaction, maintains a sliding window of
per-wallet activity, scores wallets with the ML model (plus a hard directional-
burst rule), and auto-submits a signed EIP-712 attestation when a wallet's
behaviour crosses the toxicity threshold. This closes the autonomy gap: nobody
has to run `detector.run` or `ScoreWallet` by hand.

Detection notes (why time-window, not block-window):
  The demo attacker fires swaps ~2.5–4s apart — on Unichain's 1s blocks each
  lands in its own block, so the block-based burst/sandwich features in
  features.py read 0 for it. The keeper instead measures burstiness as
  inter-swap *time* gaps and directional pressure as the fraction of
  consecutive same-direction swaps, then feeds those into the same model.

The keeper only ever *raises* scores; recovery is the registry's 7-day linear
decay. It never signs for a wallet unless the new score clears the current
on-chain score by KEEPER_MIN_SCORE_DELTA.

Usage:
  python -m detector.keeper            # uses ai/.env
  python -m detector.keeper --once     # process one poll cycle and exit (for tests)
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from collections import deque
from dataclasses import dataclass

from dotenv import load_dotenv
from web3 import Web3

load_dotenv()

# ── ABI / event constants ─────────────────────────────────────────────────────

_SWAP_TOPIC = Web3.keccak(
    text="Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
).hex()

_REGISTRY_ABI = [
    {
        "name": "scoreOf",
        "type": "function",
        "inputs": [{"name": "wallet", "type": "address"}],
        "outputs": [{"name": "", "type": "uint16"}],
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
    {
        "name": "updateScore",
        "type": "function",
        "inputs": [
            {
                "name": "attestation",
                "type": "tuple",
                "components": [
                    {"name": "wallet",    "type": "address"},
                    {"name": "value",     "type": "uint16"},
                    {"name": "nonce",     "type": "uint32"},
                    {"name": "deadline",  "type": "uint64"},
                    {"name": "signature", "type": "bytes"},
                ],
            }
        ],
        "outputs": [],
        "stateMutability": "nonpayable",
    },
]

# DYNAMIC_FEE_FLAG — the fee field of a dynamic-fee v4 pool key.
_DYNAMIC_FEE_FLAG = 0x800000


# ── Config ────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class KeeperConfig:
    rpc_url:           str
    registry:          str
    pool_manager:      str
    pool_id:           bytes
    poll_seconds:      float
    backfill_blocks:   int
    window_seconds:    float   # how long a swap stays in the sliding window
    burst_gap_seconds: float   # max gap between swaps to count as a burst pair
    burst_min_swaps:   int     # hard-rule trigger count …
    burst_dir_ratio:   float   # … with at least this same-direction ratio
    burst_floor_score: int     # hard-rule score floor
    submit_threshold:  int     # don't submit below this score
    min_score_delta:   int     # don't submit unless above on-chain score by this
    ignore_wallets:    frozenset[str]


def _compute_pool_id(currency0: str, currency1: str, tick_spacing: int, hooks: str) -> bytes:
    """PoolId = keccak256(abi.encode(PoolKey)) — five 32-byte words."""
    c0, c1 = sorted(
        (Web3.to_checksum_address(currency0), Web3.to_checksum_address(currency1)),
        key=lambda a: int(a, 16),
    )
    words = b"".join([
        bytes.fromhex(c0[2:]).rjust(32, b"\x00"),
        bytes.fromhex(c1[2:]).rjust(32, b"\x00"),
        _DYNAMIC_FEE_FLAG.to_bytes(32, "big"),
        tick_spacing.to_bytes(32, "big"),
        bytes.fromhex(Web3.to_checksum_address(hooks)[2:]).rjust(32, b"\x00"),
    ])
    return Web3.keccak(words)


def load_config() -> KeeperConfig:
    def need(name: str) -> str:
        v = os.environ.get(name, "")
        if not v:
            print(f"ERROR: {name} not set (see ai/.env.example).", file=sys.stderr)
            sys.exit(1)
        return v

    pool_id = _compute_pool_id(
        need("CURRENCY0"),
        need("CURRENCY1"),
        int(os.environ.get("TICK_SPACING", "60")),
        need("HOOK_ADDRESS"),
    )

    # The attestor's own (infrastructure) wallet is ignored by default so that
    # liquidity-seeding / setup transactions never self-flag the deployer.
    ignore: set[str] = set()
    if os.environ.get("ATTESTOR_PRIVATE_KEY"):
        from eth_account import Account
        ignore.add(Account.from_key(os.environ["ATTESTOR_PRIVATE_KEY"]).address.lower())
    for w in os.environ.get("KEEPER_IGNORE_WALLETS", "").split(","):
        if w.strip():
            ignore.add(w.strip().lower())

    return KeeperConfig(
        rpc_url           = os.environ.get("RPC_URL", "https://sepolia.unichain.org"),
        registry          = Web3.to_checksum_address(need("REGISTRY_ADDRESS")),
        pool_manager      = Web3.to_checksum_address(need("POOL_MANAGER_ADDRESS")),
        pool_id           = pool_id,
        poll_seconds      = float(os.environ.get("KEEPER_POLL_SECONDS", "2")),
        backfill_blocks   = int(os.environ.get("KEEPER_BACKFILL_BLOCKS", "10")),
        window_seconds    = float(os.environ.get("KEEPER_WINDOW_SECONDS", "600")),
        # 30s: on public testnet RPCs the bots' receipt-waits stretch a "tight burst"
        # to 8-25s between swaps; direction ratio is what separates toxic from clean.
        burst_gap_seconds = float(os.environ.get("KEEPER_BURST_GAP_SECONDS", "30")),
        burst_min_swaps   = int(os.environ.get("KEEPER_BURST_MIN_SWAPS", "4")),
        burst_dir_ratio   = float(os.environ.get("KEEPER_BURST_DIR_RATIO", "0.8")),
        burst_floor_score = int(os.environ.get("KEEPER_BURST_FLOOR_SCORE", "8000")),
        submit_threshold  = int(os.environ.get("KEEPER_SUBMIT_THRESHOLD", "3000")),
        min_score_delta   = int(os.environ.get("KEEPER_MIN_SCORE_DELTA", "500")),
        ignore_wallets    = frozenset(ignore),
    )


# ── Sliding-window swap log ───────────────────────────────────────────────────

@dataclass(frozen=True)
class SwapObs:
    timestamp:    float
    zero_for_one: bool
    fee:          int    # hundredths of a bip, from the Swap event


class WalletWindow:
    """Recent swaps for one wallet, pruned to the configured window."""

    def __init__(self, window_seconds: float) -> None:
        self._window = window_seconds
        self._swaps: deque[SwapObs] = deque()

    def add(self, obs: SwapObs) -> None:
        self._swaps.append(obs)
        self.prune(obs.timestamp)

    def prune(self, now: float) -> None:
        while self._swaps and now - self._swaps[0].timestamp > self._window:
            self._swaps.popleft()

    @property
    def swaps(self) -> list[SwapObs]:
        return list(self._swaps)


def window_features(swaps: list[SwapObs], burst_gap: float) -> dict[str, float]:
    """Map the wallet's recent activity into the model's feature space.

    burst_ratio    — fraction of swaps following the previous one within burst_gap
    sandwich_ratio — directional pressure: fraction of consecutive same-direction pairs
    """
    n = len(swaps)
    if n == 0:
        return {k: 0.0 for k in (
            "swap_count_7d", "price_impact_mean", "price_impact_max",
            "sandwich_ratio", "burst_ratio", "new_wallet_flag", "hist_tox_score_7d",
        )}

    burst_pairs = same_dir_pairs = 0
    for prev, cur in zip(swaps, swaps[1:]):
        if cur.timestamp - prev.timestamp <= burst_gap:
            burst_pairs += 1
        if cur.zero_for_one == prev.zero_for_one:
            same_dir_pairs += 1
    pairs = max(n - 1, 1)

    return {
        "swap_count_7d":     min(n / 1000.0, 1.0),
        "price_impact_mean": 0.0,   # stubbed on-chain too (Phase 4)
        "price_impact_max":  0.0,
        "sandwich_ratio":    same_dir_pairs / pairs,
        "burst_ratio":       burst_pairs / pairs,
        "new_wallet_flag":   0.0,   # cheap default; window behaviour dominates
        "hist_tox_score_7d": 0.0,
    }


def same_direction_ratio(swaps: list[SwapObs]) -> float:
    if len(swaps) < 2:
        return 0.0
    same = sum(1 for p, c in zip(swaps, swaps[1:]) if p.zero_for_one == c.zero_for_one)
    return same / (len(swaps) - 1)


# ── Keeper ────────────────────────────────────────────────────────────────────

class Keeper:
    def __init__(self, cfg: KeeperConfig) -> None:
        self.cfg = cfg
        self.w3 = Web3(Web3.HTTPProvider(cfg.rpc_url))
        self.registry = self.w3.eth.contract(address=cfg.registry, abi=_REGISTRY_ABI)
        self.windows: dict[str, WalletWindow] = {}
        self._block_ts: dict[int, float] = {}
        self.last_block = max(0, self.w3.eth.block_number - cfg.backfill_blocks)

    # ── chain reads ──

    def _timestamp(self, block_number: int) -> float:
        if block_number not in self._block_ts:
            self._block_ts[block_number] = float(
                self.w3.eth.get_block(block_number)["timestamp"]
            )
            if len(self._block_ts) > 4096:
                self._block_ts.clear()
        return self._block_ts[block_number]

    def fetch_new_swaps(self) -> list[tuple[str, SwapObs]]:
        """Return (wallet, SwapObs) for Glyph-pool swaps since the last poll."""
        latest = self.w3.eth.block_number
        if latest <= self.last_block:
            return []

        out: list[tuple[str, SwapObs]] = []
        frm = self.last_block + 1
        while frm <= latest:
            to = min(frm + 999, latest)
            logs = self.w3.eth.get_logs({
                "fromBlock": frm,
                "toBlock":   to,
                "address":   self.cfg.pool_manager,
                "topics":    ["0x" + _SWAP_TOPIC.removeprefix("0x"),
                              "0x" + self.cfg.pool_id.hex().removeprefix("0x")],
            })
            for log in logs:
                tx = self.w3.eth.get_transaction(log["transactionHash"])
                wallet = tx["from"].lower()
                data = bytes(log["data"])
                amount0 = int.from_bytes(data[0:32], "big", signed=True)
                fee     = int.from_bytes(data[160:192], "big")
                out.append((wallet, SwapObs(
                    timestamp    = self._timestamp(log["blockNumber"]),
                    zero_for_one = amount0 < 0,
                    fee          = fee,
                )))
            frm = to + 1

        self.last_block = latest
        return out

    # ── scoring + submission ──

    def evaluate(self, wallet: str) -> int:
        """Score a wallet from its window: ML model + hard directional-burst floor."""
        from detector.model import score as model_score

        swaps = self.windows[wallet].swaps
        feats = window_features(swaps, self.cfg.burst_gap_seconds)
        ml = model_score(feats)

        final = ml
        if (
            len(swaps) >= self.cfg.burst_min_swaps
            and same_direction_ratio(swaps) >= self.cfg.burst_dir_ratio
            and feats["burst_ratio"] >= 0.5
        ):
            final = max(final, self.cfg.burst_floor_score)
        return final

    def maybe_submit(self, wallet: str, new_score: int) -> None:
        from detector.attestor import sign_attestation
        from detector.safety import check_and_record

        wallet_cs = Web3.to_checksum_address(wallet)
        current = int(self.registry.functions.scoreOf(wallet_cs).call())

        if new_score < self.cfg.submit_threshold:
            return
        if new_score <= current + self.cfg.min_score_delta:
            _log(f"{_short(wallet)} scored {new_score} but on-chain is already {current} — skipping")
            return

        nonce = int(self.registry.functions.scoreDataOf(wallet_cs).call()[2]) + 1
        check_and_record(wallet_cs, nonce)  # replay + rate-limit guard
        att = sign_attestation(wallet_cs, new_score, nonce)

        account = self.w3.eth.account.from_key(os.environ["ATTESTOR_PRIVATE_KEY"])
        tx = self.registry.functions.updateScore(
            (att.wallet, att.value, att.nonce, att.deadline, att.signature)
        ).build_transaction({
            "from":  account.address,
            "nonce": self.w3.eth.get_transaction_count(account.address),
            "gas":   200_000,
        })
        signed = account.sign_transaction(tx)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

        if receipt["status"] == 1:
            _log(f"🚨 FLAGGED {_short(wallet)}: score {current} → {new_score} "
                 f"(nonce {nonce}, tx {tx_hash.hex()[:10]}…)")
        else:
            _log(f"⚠️  updateScore for {_short(wallet)} reverted (tx {tx_hash.hex()[:10]}…)")

    # ── main loop ──

    def poll_once(self) -> None:
        swaps = self.fetch_new_swaps()
        touched: set[str] = set()

        for wallet, obs in swaps:
            _log(f"swap by {_short(wallet)}  dir={'0→1' if obs.zero_for_one else '1→0'}"
                 f"  fee={obs.fee / 10_000:.2f}%")
            if wallet in self.cfg.ignore_wallets:
                continue
            self.windows.setdefault(
                wallet, WalletWindow(self.cfg.window_seconds)
            ).add(obs)
            touched.add(wallet)

        for wallet in touched:
            new_score = self.evaluate(wallet)
            n = len(self.windows[wallet].swaps)
            _log(f"{_short(wallet)}  window={n} swaps  model score → {new_score}/10000")
            self.maybe_submit(wallet, new_score)

    def run(self) -> None:
        _log(f"Glyph keeper watching pool 0x{self.cfg.pool_id.hex().removeprefix('0x')[:16]}… "
             f"on {self.cfg.pool_manager} from block {self.last_block + 1}")
        _log(f"burst rule: ≥{self.cfg.burst_min_swaps} swaps, "
             f"≥{self.cfg.burst_dir_ratio:.0%} same-direction, "
             f"gaps ≤{self.cfg.burst_gap_seconds:.0f}s → floor {self.cfg.burst_floor_score}")
        while True:
            try:
                self.poll_once()
            except KeyboardInterrupt:
                raise
            except Exception as exc:  # RPC hiccups must not kill the loop
                _log(f"⚠️  poll error: {exc}")
            time.sleep(self.cfg.poll_seconds)


# ── Helpers / entry point ─────────────────────────────────────────────────────

def _short(addr: str) -> str:
    return addr[:8] + "…" + addr[-4:]


def _log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Glyph autonomous scoring keeper")
    parser.add_argument("--once", action="store_true", help="run one poll cycle and exit")
    args = parser.parse_args()

    if "ATTESTOR_PRIVATE_KEY" not in os.environ:
        print("ERROR: ATTESTOR_PRIVATE_KEY not set.", file=sys.stderr)
        sys.exit(1)

    keeper = Keeper(load_config())
    if args.once:
        keeper.poll_once()
    else:
        keeper.run()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
