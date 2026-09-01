"""Replay 30 days of real ETH/USD price history through a Glyph pool and a plain 0.30% pool.

Method
------
A constant-product pool holds ETH and USDC. The external price series is real Binance
ETH/USDT 1-minute closes (`fetch.py`), standing in for the price an arbitrageur can trade
against elsewhere. Each minute:

1. The external price moves.
2. An arbitrageur solves for the profit-maximising trade against the pool given the fee it
   would be charged, and executes it if the profit is positive. This is the mechanical
   definition of LVR: the arbitrageur's profit is the LP's loss.
3. A stream of uninformed swaps arrives — random direction, lognormal size — representing
   the retail flow LPs actually want.

The only difference between the two pools is the fee function. The plain pool charges
0.30% always. The Glyph pool charges `FlowRisk.assembleFee`, which is mirrored in
`fees.py` and proven equal to the deployed Solidity by `ai/tests/test_parity.py`.

Assumptions, stated plainly
---------------------------
- Full-range liquidity, so `L / sqrtP` is the true reserve and the size term is exact here
  in a way it is not for a concentrated position.
- One arbitrageur, unconstrained by gas, acting on every profitable opportunity. This
  *overstates* arbitrage in both pools, and is the conservative choice: it is the regime
  where a fee on arbitrage matters least, because the arbitrageur is maximally efficient.
- The arbitrageur is a fresh wallet every time (score 0, trust 0), which is the sybil case
  the design is built for. They therefore also pay the unproven-size premium.
- Uninformed flow is synthetic. Its *arrival rate and size distribution* are assumptions;
  its treatment by the fee model is not, and the fraction of it that pays a premium is
  reported as a cost rather than buried.
"""

from __future__ import annotations

import json
import math
import random
import sys
from dataclasses import dataclass, field
from pathlib import Path

from fees import BASE_FEE, Inputs, arb_premium, assemble_fee, unproven_premium

DATA = Path(__file__).parent / "data" / "ETHUSDT-1m.json"

PLAIN_FEE = BASE_FEE  # 3000 pips == 0.30%
TVL_USD = 10_000_000.0
UNINFORMED_PER_MIN = 2.0
UNINFORMED_MEDIAN_USD = 1_200.0
UNINFORMED_SIGMA = 1.2
SEED = 20_260_901


@dataclass
class Pool:
    name: str
    x: float  # ETH
    y: float  # USDC
    glyph: bool

    arb_trades: int = 0
    arb_profit_usd: float = 0.0  # what the arbitrageur kept
    arb_fees_usd: float = 0.0  # what arbitrage paid the pool

    uninformed_trades: int = 0
    uninformed_fees_usd: float = 0.0
    uninformed_overpaying: int = 0  # paid strictly more than 0.30%, for any reason
    uninformed_overpay_usd: float = 0.0
    uninformed_hit_by_arb: int = 0  # ... because L1 read them as gap-closing
    uninformed_hit_by_size: int = 0  # ... because L3a read them as large and unproven

    fee_samples: list = field(default_factory=list)

    @property
    def k(self) -> float:
        return self.x * self.y

    @property
    def price(self) -> float:
        return self.y / self.x

    def _fee_pips(self, closes_gap: bool, divergence_bps: int, notional_usd: float) -> int:
        if not self.glyph:
            return PLAIN_FEE
        reserve_usd = self.y  # USDC side of a full-range pool == half the TVL
        size_bps = int(notional_usd * 10_000 / reserve_usd) if reserve_usd > 0 else 0
        return assemble_fee(
            Inputs(divergence_bps=divergence_bps, closes_gap=closes_gap, size_bps=size_bps)
        )

    def divergence_bps(self, p_ext: float) -> int:
        return int(abs(self.price - p_ext) / p_ext * 10_000)


def _arb(pool: Pool, p_ext: float) -> None:
    """Execute the arbitrageur's profit-maximising trade, if one exists."""
    div = pool.divergence_bps(p_ext)

    # Two passes: the fee depends on trade size, and size depends on the fee.
    notional = 0.0
    for _ in range(3):
        f = pool._fee_pips(closes_gap=True, divergence_bps=div, notional_usd=notional) / 1e6
        k, x, y = pool.k, pool.x, pool.y

        if pool.price < p_ext:  # pool ETH is cheap: arb buys ETH with USDC
            target = math.sqrt(p_ext * k * (1 - f))
            if target <= y:
                return
            dy = (target - y) / (1 - f)
            notional = dy
        else:  # pool ETH is dear: arb sells ETH for USDC
            target = math.sqrt(k * (1 - f) / p_ext)
            if target <= x:
                return
            dx = (target - x) / (1 - f)
            notional = dx * p_ext

    if notional <= 0:
        return

    f = pool._fee_pips(closes_gap=True, divergence_bps=div, notional_usd=notional) / 1e6
    k, x, y = pool.k, pool.x, pool.y

    if pool.price < p_ext:
        dy = notional
        dy_eff = dy * (1 - f)
        dx_out = x - k / (y + dy_eff)
        profit = dx_out * p_ext - dy
        if profit <= 0:
            return
        pool.x -= dx_out
        pool.y += dy_eff
        pool.arb_fees_usd += dy * f
    else:
        dx = notional / p_ext
        dx_eff = dx * (1 - f)
        dy_out = y - k / (x + dx_eff)
        profit = dy_out - dx * p_ext
        if profit <= 0:
            return
        pool.x += dx_eff
        pool.y -= dy_out
        pool.arb_fees_usd += dx * f * p_ext

    pool.arb_trades += 1
    pool.arb_profit_usd += profit
    pool.fee_samples.append(f * 1e6)


def _uninformed(pool: Pool, p_ext: float, buy_eth: bool, notional_usd: float) -> None:
    div = pool.divergence_bps(p_ext)
    # Buying ETH pushes the pool price up, which closes the gap when the pool is below.
    closes = (pool.price < p_ext) == buy_eth

    f = pool._fee_pips(closes_gap=closes, divergence_bps=div, notional_usd=notional_usd) / 1e6
    k, x, y = pool.k, pool.x, pool.y

    if buy_eth:
        dy = notional_usd
        dy_eff = dy * (1 - f)
        dx_out = x - k / (y + dy_eff)
        if dx_out <= 0 or dx_out >= x:
            return
        pool.x -= dx_out
        pool.y += dy_eff
        paid = dy * f
    else:
        dx = notional_usd / p_ext
        dx_eff = dx * (1 - f)
        dy_out = y - k / (x + dx_eff)
        if dy_out <= 0 or dy_out >= y:
            return
        pool.x += dx_eff
        pool.y -= dy_out
        paid = dx * f * p_ext

    pool.uninformed_trades += 1
    pool.uninformed_fees_usd += paid
    if f * 1e6 > PLAIN_FEE + 1e-9:
        pool.uninformed_overpaying += 1
        pool.uninformed_overpay_usd += notional_usd * (f - PLAIN_FEE / 1e6)
        # The two premiums an uninformed swap can trip are different failures with different
        # fixes, so they are counted apart. L1 firing on uninformed flow is a misclassification.
        # L3a firing is the design working: a large swap from a wallet with no record is
        # exactly what the unproven premium exists to price, whatever its intent.
        reserve_usd = pool.y
        size_bps = int(notional_usd * 10_000 / reserve_usd) if reserve_usd > 0 else 0
        if arb_premium(div, closes) > 0:
            pool.uninformed_hit_by_arb += 1
        if unproven_premium(size_bps) > 0:
            pool.uninformed_hit_by_size += 1


def run() -> dict:
    series = json.loads(DATA.read_text())
    rng = random.Random(SEED)

    p0 = series[0][1]
    half = TVL_USD / 2
    mk = lambda name, glyph: Pool(name=name, x=half / p0, y=half, glyph=glyph)
    plain, glyph = mk("plain 0.30%", False), mk("glyph", True)

    for _, p_ext in series:
        # Arbitrage is continuous in reality: any deviation wide enough to pay for itself is
        # closed in the next block. Interleaving it with uninformed flow — rather than running
        # it once a minute — is what keeps the pool pinned inside the no-arbitrage band, and
        # without that the uninformed order flow random-walks the price away and manufactures
        # arbitrage that would never have existed.
        for pool in (plain, glyph):
            _arb(pool, p_ext)

        n = int(UNINFORMED_PER_MIN) + (1 if rng.random() < UNINFORMED_PER_MIN % 1 else 0)
        for _ in range(n):
            buy = rng.random() < 0.5
            notional = min(
                UNINFORMED_MEDIAN_USD * math.exp(rng.gauss(0, UNINFORMED_SIGMA)),
                TVL_USD * 0.05,
            )
            for pool in (plain, glyph):
                _uninformed(pool, p_ext, buy, notional)
                _arb(pool, p_ext)

    days = (series[-1][0] - series[0][0]) / 86_400_000
    return {"days": days, "minutes": len(series), "plain": plain, "glyph": glyph}


def report(r: dict) -> str:
    plain, glyph = r["plain"], r["glyph"]
    lines = []
    add = lines.append

    add(f"window                       {r['days']:.1f} days ({r['minutes']:,} minutes of real ETH/USD)")
    add(f"pool                         ${TVL_USD:,.0f} full-range, {UNINFORMED_PER_MIN}/min uninformed flow")
    add("")
    add(f"{'':28} {'plain 0.30%':>16} {'Glyph':>16}")
    add(f"{'arbitrage trades':28} {plain.arb_trades:>16,} {glyph.arb_trades:>16,}")
    add(f"{'kept by arbitrageurs':28} {plain.arb_profit_usd:>16,.0f} {glyph.arb_profit_usd:>16,.0f}")
    add(f"{'paid to the pool by arb':28} {plain.arb_fees_usd:>16,.0f} {glyph.arb_fees_usd:>16,.0f}")
    add(f"{'uninformed fees to pool':28} {plain.uninformed_fees_usd:>16,.0f} {glyph.uninformed_fees_usd:>16,.0f}")

    total_p = plain.arb_fees_usd + plain.uninformed_fees_usd
    total_g = glyph.arb_fees_usd + glyph.uninformed_fees_usd
    add(f"{'TOTAL to the pool':28} {total_p:>16,.0f} {total_g:>16,.0f}")
    add("")

    gross_p = plain.arb_profit_usd + plain.arb_fees_usd
    gross_g = glyph.arb_profit_usd + glyph.arb_fees_usd
    add(f"share of gross arbitrage kept by the pool:")
    add(f"  plain   {plain.arb_fees_usd / gross_p * 100:5.1f}%")
    add(f"  Glyph   {glyph.arb_fees_usd / gross_g * 100:5.1f}%")
    add("")
    add(f"extra returned to LPs by Glyph   ${total_g - total_p:,.0f} over {r['days']:.0f} days")
    add(f"  annualised on ${TVL_USD:,.0f}   {(total_g - total_p) / TVL_USD * 365 / r['days'] * 100:.2f}% of TVL")
    add("")
    n = glyph.uninformed_trades
    add("cost side — uninformed flow that paid more than 0.30%:")
    add(f"  {glyph.uninformed_overpaying:,} of {n:,} swaps "
        f"({glyph.uninformed_overpaying / n * 100:.2f}%), costing ${glyph.uninformed_overpay_usd:,.0f}")
    add(f"    misread as arbitrage by L1   {glyph.uninformed_hit_by_arb:>7,} "
        f"({glyph.uninformed_hit_by_arb / n * 100:.2f}%)")
    add(f"    large + unproven, by design  {glyph.uninformed_hit_by_size:>7,} "
        f"({glyph.uninformed_hit_by_size / n * 100:.2f}%)")
    return "\n".join(lines)


if __name__ == "__main__":
    if not DATA.exists():
        sys.exit(f"{DATA} missing — run `python fetch.py 30` first")
    print(report(run()))
