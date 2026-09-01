# Backtest — what the fee model does to real flow

Every other claim in this repository is about *mechanism*: what the hook charges and why. This
one is about *magnitude*, and it is the only way to answer the question a judge or an LP
actually asks — **how much does this matter, and what does it cost the people it is not aimed
at?**

Reproduce it:

```bash
cd ai/backtest
python3 fetch.py 30       # 30 days of real ETH/USD, 1-minute, no API key
python3 lvr.py            # the headline table
python3 sweep.py          # the tolerance sweep that retuned a constant
python3 sensitivity.py    # does the conclusion survive different assumptions?
```

---

## Method

A constant-product pool holds ETH and USDC. The external price is **43,200 minutes of real
Binance ETH/USDT closes** — the price an arbitrageur can trade against elsewhere. Each minute:

1. The external price moves.
2. An arbitrageur solves for the profit-maximising trade against the pool *given the fee it
   would be charged*, and executes it if profitable. That trade's profit is, mechanically, the
   LP's loss — this is what LVR is.
3. Uninformed swaps arrive: random direction, lognormal size. Arbitrage is re-run after each
   one, because in reality any deviation wide enough to pay for itself is closed in the next
   block.

Two pools run side by side on the identical price path and the identical flow. The **only**
difference is the fee function: one charges a flat 0.30%, the other calls
`FlowRisk.assembleFee`.

### The fee model is the deployed one, and that is proven, not asserted

The simulation prices millions of swaps, so it uses a Python mirror of `FlowRisk.sol`
(`ai/backtest/fees.py`) rather than an EVM. A mirror is worthless if it drifts, so:

- `contract/test/FlowRiskParity.t.sol` sweeps a 2,500-point grid across **every branch** of
  `assembleFee` — both sides of the direction test, the tolerance boundary at 39/40/41 bps, the
  unproven free-size boundary, all three segments of the toxicity curve, the trust floor clamp
  — and writes the results straight out of the EVM to CSV.
- `ai/tests/test_parity.py` recomputes each row in Python and asserts exact equality.

If the two ever diverge, that test fails and these numbers are known to be describing a model
nobody shipped.

---

## The finding that changed the contract

The first run said something alarming: **44% of uninformed swaps were paying more than 0.30%.**

That is not a simulation artefact. It is arithmetic, and it was a real flaw in the deployed
parameterisation.

`ARB_TOLERANCE_BPS` shipped at 10 bps, reasoned about as "oracle noise". But a pool's
**no-arbitrage band is set by its base fee**: below 30 bps of divergence, closing the gap does
not cover the 0.30% fee, so no rational arbitrageur trades at all. A tolerance of 10 bps sits
*inside* that band — a region where, by construction, there is no arbitrage to catch. Everything
it charged was uninformed flow that happened to move toward the reference, which is about half
of all uninformed flow.

Sweeping the constant over the full 30 days:

| tolerance | LP gain | uninformed swaps hit by L1 | gross arbitrage kept by pool |
|---:|---:|---:|---:|
| 0 bps | $476,533 | 49.95% | 92.1% |
| 10 bps *(as shipped)* | $362,784 | 43.74% | 91.0% |
| 20 bps | $258,881 | 34.52% | 89.4% |
| 30 bps | $174,958 | 15.01% | 87.0% |
| **40 bps** *(retuned)* | **$143,274** | **1.49%** | **82.4%** |
| 60 bps | $111,639 | 0.60% | 75.2% |
| 100 bps | $79,125 | 0.47% | 67.4% |

The elbow is unmistakable. Moving 30 → 40 bps cuts collateral damage by **90%** (15.01% → 1.49%)
for **18%** of the LP gain. Moving 40 → 60 buys almost nothing more and costs another 22%.

**40 = the 30 bp band edge + a 10 bp cushion**, because the arbitrageur's own trade leaves the
price sitting on the band edge and uninformed flow jitters it back and forth across.

The constant was changed, the hook was redeployed, and the relationship is now pinned by
`test_arb_toleranceClearsTheNoArbitrageBand` so it cannot be silently undone.

---

## Headline results

30 days, $10M full-range pool, 0.73× daily turnover.

| | plain 0.30% | Glyph |
|---|---:|---:|
| arbitrage trades | 27,001 | 31,934 |
| **kept by arbitrageurs** | **$188,209** | **$72,202** |
| paid to the pool by arbitrage | $224,705 | $338,946 |
| uninformed fees to the pool | $631,915 | $660,949 |
| **total to the pool** | **$856,621** | **$999,895** |

### 1. The pool keeps 82% of gross arbitrage, against 54%

This is the number that matters, because it is a property of the mechanism rather than of the
assumptions. A plain 0.30% pool already captures some LVR — the fee is not zero — but more than
**45% of the gross arbitrage walks out of the pool**. Glyph reduces that to under 18%.

### 2. 98.9% of uninformed swaps are never touched by the arbitrage premium

Of 86,400 uninformed swaps, 1,287 (1.49%) paid more than 0.30%. Those split into two very
different things:

| | count | share | what it is |
|---|---:|---:|---|
| misread as arbitrage by L1 | 903 | **1.05%** | a genuine false positive |
| large, from an unproven wallet (L3a) | 384 | 0.44% | the design working as intended |

Only the first is a defect. The second is precisely what the unproven premium exists to price:
a large swap from a wallet with no record, which is the sybil case, whatever its intent.

**No uninformed swap that widened the gap paid a premium, at any size, from any wallet** — that
is guaranteed by construction and fuzz-tested as `test_arb_gapWideningIsAlwaysFree`.

### 3. $143,274 returned to LPs over 30 days

17.4% of TVL annualised, at 0.73× daily turnover. State the turnover whenever you quote this:
like all fee revenue it scales with volume, so it is the least portable of the three numbers.

---

## Does it survive different assumptions?

| TVL | flow/min | turnover/day | arbitrage kept by pool | L1 false positives | gain %TVL/yr |
|---:|---:|---:|---:|---:|---:|
| $2M | 0.5 | 1.46× | 77.3% | 5.52% | 210.6% |
| $2M | 2.0 | 6.22× | 77.3% | 14.24% | 885.8% |
| $2M | 8.0 | 26.75× | 76.8% | 19.57% | 3894.3% |
| $10M | 0.5 | 0.18× | 83.1% | 0.38% | 4.5% |
| **$10M** | **2.0** | **0.73×** | **82.4%** | **1.05%** | **17.4%** |
| $10M | 8.0 | 3.01× | 81.8% | 1.72% | 80.4% |
| $50M | 0.5 | 0.04× | 84.8% | 0.15% | 0.7% |
| $50M | 2.0 | 0.14× | 86.5% | 0.08% | 0.8% |
| $50M | 8.0 | 0.57× | 88.0% | 0.05% | 1.3% |

Reading it honestly:

- **The 77–88% arbitrage capture is stable** across a 25× range of pool size and a 16× range of
  flow. That conclusion is the mechanism, not the parameters.
- **The %TVL figure is not a mechanism property.** It tracks turnover, exactly as fee revenue
  does in any pool. Quoting it without the turnover is meaningless.
- **The false-positive rate rises with turnover**, because more flow means the pool spends more
  time displaced from the reference. At realistic turnover for a major pair (0.1×–3×/day) it
  runs 0.05%–1.7%.
- **The $2M rows are outside the realistic envelope** and are shown deliberately. A $2M pool
  turning over 27× a day is not a market that exists; those rows are where the model breaks, and
  the breakage is visible rather than hidden.

---

## What this backtest is not

Stated plainly, because a backtest that oversells itself is worse than none.

- **The uninformed flow is synthetic.** Its arrival rate and size distribution are assumptions.
  Its *treatment by the fee model* is not — that is the deployed arithmetic — and the sensitivity
  table exists because the assumption is load-bearing.
- **It is full-range liquidity.** Concentrated positions hold less than `L / sqrtP`, so a real
  pool's size term would read differently. This is the same limitation disclosed as #3 in the
  README, and it errs toward under-charging.
- **One arbitrageur, no gas costs, acting on every profitable opportunity.** This *overstates*
  arbitrage in both pools. It is the conservative choice: it is the regime where charging for
  arbitrage matters least, because the arbitrageur is maximally efficient.
- **It does not model L2 or L3b.** No sandwiches, no toxicity scores. The sandwich rebate is
  demonstrated on-chain instead ([DEPLOYMENT.md](DEPLOYMENT.md)), where it is worth more than a
  simulation.
- **One asset, one 30-day window.** ETH/USD from 2 August to 1 September 2026. A different
  window with different realized volatility moves the dollar figures; it does not move the
  capture ratio, which is set by the fee curve.
