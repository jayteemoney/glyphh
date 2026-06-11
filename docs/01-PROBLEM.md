# 01 — The problem: LPs are the exit liquidity of MEV

## The core failure of passive AMM liquidity

A liquidity provider in a constant-function AMM makes a standing offer to trade at the pool's
current price — to *anyone*. That "anyone" is the problem. Order flow is not homogeneous:

- **Uninformed (benign) flow** — retail swaps, rebalances, payments. Roughly as likely to
  trade in either direction; the LP earns the fee and keeps it.
- **Informed (toxic) flow** — arbitrageurs closing the gap against CEX prices, sandwich bots
  bracketing victim trades, statistical MEV strategies. These trade *only* when the pool's
  price is stale or manipulable — which means the LP is, by construction, always on the losing
  side of these trades.

The formalization of this loss is **LVR — loss-versus-rebalancing** (Milionis, Moallemi,
Roughgarden & Zhang, 2022): the systematic underperformance of an AMM position against a
continuously-rebalanced portfolio, caused by trading at stale prices with better-informed
counterparties. Empirical follow-ups consistently find that for volatile pairs, **fees at
standard tiers do not cover LVR** — passive LP positions on major ETH pairs frequently lose
money relative to simply holding, once arbitrage losses are netted against fee income.
Sandwich extraction compounds it: hundreds of millions of dollars have been extracted from
AMM users by sandwich bots alone since 2020 (Flashbots' MEV-Explore measured >$675M of
extracted MEV on Ethereum even before the Merge, the majority touching DEX liquidity).

The result is a structural tax with three downstream effects:

1. **Liquidity flight** — sophisticated LPs withdraw from volatile pairs or demand wider fee
   tiers; passive LPs lose silently and leave when they notice.
2. **Worse prices for everyone** — thinner liquidity at higher fee tiers means more slippage
   for the honest traders who remain.
3. **A subsidy to the most extractive actors** — the fee an MEV bot pays is identical to the
   fee a first-time retail user pays. The pool literally cannot tell them apart.

## Why the existing answers don't close the gap

Every deployed defense reacts to a **symptom** of toxicity, never to the **agent**:

| Defense | Watches | Blind spot |
|---|---|---|
| Static fee tiers (0.05/0.30/1%) | Nothing — set once | One fee for sharks and minnows alike |
| Volatility-reactive hooks (e.g. AdaptiveSwap) | Realized volatility | Penalizes *all* traders when markets move — including the honest ones |
| Oracle-divergence hooks (e.g. DetoxHook) | Pool-vs-Pyth price gap | Only catches stale-price arbitrage, and only *while* the gap exists |
| Private order flow / MEV protection RPCs | The victim's transaction | Protects the *swapper* from sandwiches; does nothing for the *LP* against arb flow |
| Auction-based designs (am-AMM, MEV taxes) | The right to extract | Redistributes MEV, doesn't reprice the extractor; research-stage complexity |

Two failures are common to all of them:

- **Amnesia.** Every swap is evaluated in isolation. A bot that sandwiched a pool a thousand
  times pays the same fee on swap 1,001. There is no memory, so there is no deterrence.
- **Locality.** Each pool defends itself alone. An attacker priced out of (or detected in)
  one pool simply rotates to the next one. Defense doesn't propagate; attacks do.

## The question Glyph asks

Markets solved this problem centuries ago: counterparties have *reputations*, and known-bad
actors get worse prices or no quote at all. On-chain, the entire behavioral history of every
wallet is public — yet no AMM uses it.

**What if the pool could remember? What if every pool remembered for every other?**

That is the gap Glyph fills: a per-wallet, decaying, on-chain reputation score — written by an
ML detector, by the pools themselves, and by a cross-pool aggregation network — that the hook
turns directly into the swap fee, with the toxicity premium routed back to the LPs who bear
the cost. The problem is adverse selection; the missing primitive is identity-priced
liquidity. See [02 — The solution](02-SOLUTION.md).
