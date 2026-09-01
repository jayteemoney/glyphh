# 04 — Who Glyph is for, and where it stands

## Primary users

### 1. Passive LPs (the protected party)
The retail or fund LP who deposits into a volatile pair and bleeds LVR without ever seeing it
itemized. Glyph changes their unit economics at the source: the swap that captures a
divergence pays 60% of it back into the pool, every time, whether or not anyone has ever seen
that wallet before. They do nothing to opt in except choose a Glyph pool.

The honest framing of the benefit: Glyph does not stop arbitrage, and should not — arbitrage
is what keeps the pool's price correct. It makes the arbitrageur **pay the pool for the
privilege**, in proportion to what they are taking.

### 2. Traders who get sandwiched (the party nobody else pays)
Uniquely among MEV defences, Glyph has a user who receives money. A trader squeezed between
two legs of a sandwich is credited the attacker's surcharge and can withdraw it. No
registration, no LP position, no proof to submit — the hook escrows to their address in the
block it happened, and they claim.

### 3. Honest and proven traders (the unexpected winners)
Ordinary flow pays 0.30%, in every market condition, at any size, from any wallet. Flow that
has proven itself over ten settled swaps pays as little as **0.05%** — six times cheaper than
the pool's base tier and cheaper than most pools of any kind.

This is the half of the thesis that answers "sustainable low-fee liquidity" literally: not a
cheap pool subsidised by nobody, but a **0.30% pool that quotes 0.05% to earned flow, funded by
what extractive flow pays**.

### 4. Pool deployers and token teams (the buyers)
Whoever initializes the pool chooses the hook. Token teams launching liquidity today choose
between being sandwiched into a bad chart and paying market makers. A Glyph pool gives them a
concrete answer: arbitrage pays the pool, sandwich victims are made whole by their attacker,
and steady users get a fee tier nobody else can offer them.

### 5. The wider protocol ecosystem (the second act)
`ReputationRegistry` is a freestanding contract any protocol can read: lending markets pricing
borrower risk, perps venues tiering taker fees, RFQ systems filtering quote recipients, sybil
screens. Each new consumer makes a high toxicity score more expensive to carry and an earned
trust score more valuable to hold. The hook is its first consumer, not its only one.

## Positioning statement

> For **LPs and pool deployers on Uniswap v4** who lose value to informed flow, **Glyph** is a
> hook that **prices each swap by what it does to the pool** — charging the swap that captures
> a divergence, paying sandwich victims out of their attacker's own surcharge, and quoting
> earned flow below the base tier. Unlike volatility- or reputation-based designs, its first
> two layers need no identity at all, so wallet rotation does not defeat them.

## Where the idea stands

- **Theme-exact.** UHI10's theme is *The Fair Flow Frontier: MEV protection and sustainable
  low-fee liquidity*. Glyph is both halves in one mechanism: extraction is repriced at the
  source (MEV protection) and the proceeds fund a sub-base fee tier for proven flow
  (sustainable low fees). It was not retrofitted to the theme; the theme is what the redesign
  was aimed at.
- **Honest about what is and is not new.** Oracle-divergence capture already exists and we say
  so. The attacker-funded victim rebate and the inversion of reputation into a discount are, as
  far as we can find, unprecedented. See [03 — The ecosystem gap](03-ECOSYSTEM-GAP.md).
- **Defensible by data, not by code.** The contracts are MIT and forkable. The moat is the
  registry's accumulated behavioural history and the pools writing into it — a fork starts with
  an empty memory, which is the one asset this design makes valuable.
- **Honest about its maturity.** Identity is a three-tier heuristic; sandwich detection has a
  named and tested false positive; the demo pool prices against a settable reference because
  mock tokens have no Pyth feed. All three are disclosed in the README with their production
  paths, and none of them touch L1.

## The growth loop

1. A pool adopts Glyph → arbitrage pays it, and its sandwich victims are made whole.
2. Better LP economics → deeper liquidity → better prices → more honest volume.
3. More honest volume → more wallets accumulating trust → more flow eligible for the 0.05%
   tier, which is a reason to route here rather than anywhere else.
4. More pools → more sensors writing to the registry → faster, broader detection, and a
   trust score that is worth more because more venues honour it.
5. Repeat from 1.

Steps 3 and 4 are the ones that compound, and both of them require the inversion: a discount
people want to keep is stickier than a penalty people want to escape.
