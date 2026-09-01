"""Is the headline a property of the mechanism, or of one set of assumptions?

Vary the two things the simulation assumes — pool size and how much uninformed flow
arrives — and check which conclusions survive and which are artefacts of turnover.
"""
import lvr

hdr = f"{'TVL':>12} {'flow/min':>9} {'turnover/day':>13} {'arb kept':>9} {'L1 false +':>11} {'gain %TVL/yr':>13}"
print(hdr)
print("-" * len(hdr))
for tvl in (2_000_000, 10_000_000, 50_000_000):
    for flow in (0.5, 2.0, 8.0):
        lvr.TVL_USD, lvr.UNINFORMED_PER_MIN = tvl, flow
        r = lvr.run()
        g, p = r["glyph"], r["plain"]
        gain = (g.arb_fees_usd + g.uninformed_fees_usd) - (p.arb_fees_usd + p.uninformed_fees_usd)
        share = g.arb_fees_usd / (g.arb_fees_usd + g.arb_profit_usd) * 100
        fp = g.uninformed_hit_by_arb / g.uninformed_trades * 100
        vol = g.uninformed_fees_usd / (lvr.PLAIN_FEE / 1e6)
        turn = vol / r["days"] / tvl
        print(f"{tvl:>12,} {flow:>9} {turn:>12.2f}x {share:>8.1f}% {fp:>10.2f}% "
              f"{gain / tvl * 365 / r['days'] * 100:>12.1f}%")
