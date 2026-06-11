# 04 — Who Glyph is for, and where it stands

## Primary users

### 1. Passive LPs (the protected party)
The retail or fund LP who deposits into a volatile pair and bleeds LVR without ever seeing
it itemized. Glyph changes their unit economics twice over: toxic flow pays up to ~33x the
base fee, and that premium is credited to in-range liquidity in the same transaction. For
this user, Glyph is not a feature — it's the difference between LPing being negative-EV and
positive-EV on volatile pairs. They do nothing to opt in except choose a Glyph pool.

### 2. Pool deployers and token teams (the buyers)
Whoever initializes the pool chooses the hook. Token teams launching liquidity today choose
between being sandwiched into a bad chart or paying market makers. A Glyph pool gives them a
defensible answer: "our pool reprices MEV bots automatically and pays our LPs the
difference." Liquidity attracts liquidity; protection is a listing feature.

### 3. Honest traders (the unexpected winners)
Counter-intuitively, clean flow gets a *better* deal in a Glyph pool: protected LPs supply
deeper liquidity at the 0.30% base tier than they would dare supply unprotected, and the
honest trader never pays the toxicity premium. Glyph is the rare MEV defense whose costs
fall exclusively on the extractors.

### 4. The wider protocol ecosystem (the second act)
The registry is a freestanding, read-by-anyone reputation primitive with a frozen interface.
Natural follow-on consumers: lending protocols pricing borrower risk, perps venues tiering
taker fees, RFQ/solver systems filtering quote recipients, airdrop/sybil screens. Each new
consumer adds write-incentive and read-value to the same shared layer — the "credit bureau
of DeFi" position, reached through the wedge of LP protection.

## Positioning statement

> For **LPs and pool deployers on Uniswap v4** who lose value to MEV and informed flow,
> **Glyph** is a **reputation-priced liquidity layer** that charges each swap by the
> swapper's on-chain track record and pays the premium back to LPs. Unlike volatility- or
> oracle-reactive hooks, which see the swap but never the swapper, Glyph prices the *agent*
> — with a 7-day decay that keeps it a price, never a blacklist — and propagates every
> pool's knowledge to every other pool in seconds.

## Where the idea stands

- **Theme-perfect for the moment.** The Hookathon's stated focus is *value leakage* —
  protecting LPs and making volatile-pair liquidity sustainable at low fees. Glyph is a
  direct, literal answer: leakage is repriced at the source and refunded to LPs.
- **A category of one within the hook ecosystem.** Hundreds of hooks have shipped across UHI
  cohorts — fee curves, LP managers, auction designs. None price wallet identity, and none
  share state across pools. The most-awarded adjacent project (AdaptiveSwap, volatility
  fees) is Glyph's explicit baseline comparison: it reacts to *conditions*; Glyph reacts to
  *actors*.
- **Defensible by data, not by code.** The contracts are MIT-licensed and forkable; the
  moat is the registry's accumulating behavioral graph and the network of pools writing to
  it. Forks start with an empty memory — the one thing this design makes valuable.
- **Honest about its maturity.** MVP identity is `tx.origin` (production path: hash of
  `(tx.origin, msg.sender)` + stake-weighted attestors); the ML model is demo-grade
  (production path: train on labeled MEV datasets with real price-impact features). These
  are disclosed, scoped, and none of them block the core mechanism — which is already live
  and measurably working on testnet.

## The growth loop

1. A pool adopts Glyph → its LPs lose less and earn the toxicity premium.
2. Better LP economics → deeper liquidity → better prices → more honest volume.
3. More pools → more sensors writing to the registry → faster, broader detection.
4. A richer registry → day-one protection for the next pool → repeat from 1.

Every mechanism in the system — decay, cross-pool callbacks, ZK-provable history, the
LP-donation accounting — exists to keep this loop spinning without trust bottlenecks.
