"""Sweep ARB_TOLERANCE_BPS to find where it should sit relative to the base fee."""
import fees, lvr

print(f"{'tol(bps)':>9} {'LP gain $':>12} {'uninformed overpaying':>22} {'arb kept by pool':>18}")
for tol in (0, 5, 10, 20, 30, 40, 60, 100):
    fees.ARB_TOLERANCE_BPS = tol
    r = lvr.run()
    g, p = r["glyph"], r["plain"]
    gain = (g.arb_fees_usd + g.uninformed_fees_usd) - (p.arb_fees_usd + p.uninformed_fees_usd)
    pct = g.uninformed_overpaying / g.uninformed_trades * 100
    share = g.arb_fees_usd / (g.arb_fees_usd + g.arb_profit_usd) * 100
    print(f"{tol:>9} {gain:>12,.0f} {pct:>21.2f}% {share:>17.1f}%")
