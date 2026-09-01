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

Every deployed defence reacts to a **symptom** of toxicity — a market condition that correlates
with extraction — or, in the reputation designs, to the **sender**:

| Defence | Watches | Blind spot |
|---|---|---|
| Static fee tiers (0.05/0.30/1%) | nothing — set once | one fee for sharks and minnows alike |
| Volatility-reactive hooks (AdaptiveSwap) | realized volatility | penalizes *all* traders when markets move, including the honest ones |
| Directional fees (Nezlobin) | the pool's own recent price drift | a backward-looking proxy; prices a direction, not the gap actually on the table |
| Oracle-divergence capture (DetoxHook) | pool-vs-Pyth gap | thresholded at ~2%, so the ordinary case goes uncharged; the value goes to LPs |
| Private order flow / MEV-protect RPCs | the victim's transaction | protects the *swapper* from sandwiches; does nothing for the LP against arb flow |
| Auction designs (am-AMM, MEV taxes) | the right to extract | redistributes MEV rather than repricing it; needs new market infrastructure |
| Reputation designs (including Glyph **v1**) | the sender's history | the clean state is the default and the default is free, so rotating wallets resets it |

The last row is the one worth dwelling on, because it is the trap Glyph itself fell into. If
being unknown is free, then every defence built on knowing who someone is can be defeated by
becoming unknown again. The cost of a fresh EOA is a few cents of gas.

And two failures run across the whole table:

- **The signal is a proxy.** Volatility, order size and price drift *correlate* with
  extraction. None of them *is* extraction, so each one misprices in both directions: honest
  traders pay for conditions they did not create, and a patient extractor waits for the
  conditions to pass.
- **Locality.** Each pool defends itself alone. An attacker priced out of one pool simply
  rotates to the next. Defence doesn't propagate; attacks do.

## The question Glyph asks

Every defence in the table above shares one assumption: that you can tell a toxic swap from an
honest one by looking at the *market* — the volatility, the price gap, the order size — or by
looking at the *sender*. The first is a proxy. The second is spoofable by anyone willing to
fund a fresh wallet.

There is a third thing to look at, and it is neither:

> **What does this swap do to the pool?**

A swap that moves the pool toward the true price is, by definition, capturing the divergence —
that is what LVR *is*, mechanically, not as a proxy for it. A swap that moves the pool away is
supplying the uninformed order flow LPs earn from. The distinction is available in `beforeSwap`
from two numbers neither the swapper nor the router controls: the pool's own `slot0` and a
reference price.

That question needs no identity to answer, which is why it survives wallet rotation. And it
generalises: the same "what did this do" framing identifies a sandwich from the *shape* of
three legs in a block, without knowing who sent any of them.

Reputation still has a job, but a smaller and better-chosen one — not deciding who is
dangerous, only rewarding who has proven they are not. See
[02 — The solution](02-SOLUTION.md).
