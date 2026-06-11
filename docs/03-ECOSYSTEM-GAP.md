# 03 — The ecosystem gap: the axis nobody prices

## The landscape

Defending LPs from toxic flow is one of the most active areas in AMM research and in the
hook ecosystem itself. Mapping the field by *what signal the defense reacts to*:

| Approach | Example | Signal | LP protected from | Trader memory | Cross-pool |
|---|---|---|---|---|---|
| Static fee tiers | Uniswap v3 | none | nothing specific | ✗ | ✗ |
| Volatility-reactive fees | AdaptiveSwap (UHI4 winner) | realized volatility | vol-spike arbitrage | ✗ | ✗ |
| Oracle-divergence fees | DetoxHook | pool-vs-Pyth gap | stale-price arbitrage | ✗ | ✗ |
| Private order flow | MEV-protect RPCs, CoW | the victim's tx | swapper (not LP!) from sandwiches | ✗ | ✗ |
| Auction the right to trade first | am-AMM, MEV taxes | bidding | redistributes arb profit | ✗ | ✗ |
| Permissioned pools | KYC/allowlist hooks | legal identity | everything — by excluding everyone | ✓ (binary) | ✗ |
| **Identity-priced fees** | **Glyph** | **the wallet's behavioral history** | **all repeat toxic flow** | **✓ (graded, decaying)** | **✓ (seconds)** |

Two structural observations:

1. **Every non-Glyph row is stateless about the trader.** They evaluate the swap, the moment,
   or the market — never the agent. The information that most strongly predicts whether the
   *next* swap is toxic — the swapper's own history — is public, free, and unused.
2. **Every non-Glyph row is local.** No deployed mechanism lets pool B benefit from what pool
   A learned. Attackers exploit this: detection in one venue just moves the flow.

## The gap, precisely stated

> There is no permissionless, graded, recoverable, **shared** reputation layer for AMM
> liquidity — no mechanism by which a pool can quote a worse price to a wallet that has
> demonstrably extracted from LPs before, and no mechanism by which that knowledge
> propagates between pools.

Glyph is that layer. It is deliberately **not** a blocklist (binary, permanent, governance
-heavy) and **not** another market-condition fee curve (punishes everyone when conditions
turn). It is a *price* attached to an *identity*, with decay guaranteeing the price is about
behaviour, not about the wallet per se.

## Why this is the right primitive (and not just another hook)

- **It composes.** The `ReputationRegistry` is a standalone contract with a frozen interface.
  Any v4 pool adds protection by deploying with the Glyph hook — but any *other* protocol
  (lending markets gating borrowers, perps venues tiering takers, RFQ systems filtering
  flow) can read the same registry. The hook is the first consumer, not the only one.
- **It compounds.** Every additional Glyph pool makes the registry's data better, and the
  registry makes every additional pool safer on day one — a real network effect, rare in
  hook designs, impossible for single-pool defenses.
- **It's complementary, not competitive.** Glyph stacks with everything in the table above:
  a pool can run volatility-reactive *and* reputation-priced fees; private order flow keeps
  protecting swappers while Glyph protects LPs. Glyph occupies an empty axis rather than
  fighting on an occupied one.
- **It mirrors how every mature market works.** Credit scores, prime brokerage tiering,
  exchange participant classification — pricing counterparty risk by identity and history is
  the norm everywhere except DeFi, where the data is *most* available. Glyph is the missing
  port of a proven mechanism.

## Competitive advantage against contemporary solutions

The gap analysis above shows *where* Glyph sits. This section answers the sharper question a
judge or investor actually asks: **if the alternatives improved tomorrow, what advantage
does Glyph keep?**

### Head-to-head

**vs. oracle-divergence hooks (DetoxHook and similar).**
These price one attack (stale-price arbitrage) during one window (while the gap is open).
Glyph prices the attacker. A divergence hook resets to zero knowledge the moment prices
re-converge; Glyph's registry keeps compounding. Even if a divergence hook added memory, it
would only remember one behaviour in one pool. Glyph already covers the full behavioural
surface (bursts, direction pressure, sandwich footprints, reported history) across every
pool at once.

**vs. volatility-reactive fees (AdaptiveSwap and similar).**
Volatility hooks raise fees on everyone when markets move, which is exactly when honest
traders most need to trade. That is a regressive tax with real demand cost. Glyph's fee is
flat 0.30% for honest flow in any market condition; only identified extractors pay more. A
volatility hook cannot adopt this property without becoming Glyph: it has no concept of an
identity to discriminate on.

**vs. auction designs (am-AMM, MEV taxes).**
These are elegant mechanisms for *redistributing* extraction value, and they remain mostly
research-stage because they demand new market infrastructure (continuous auctions, bidder
ecosystems, manager roles). Glyph deploys on stock v4 today, touches nothing about how
ordinary swaps work, and *removes the incentive* rather than taxing its proceeds. The two
approaches are even compatible: an am-AMM pool could still read the registry.

**vs. private order flow and intent systems (MEV-protect RPCs, CoW-style batching).**
These protect the *swapper* from sandwiches and leak no defense to the LP, who still bleeds
to arbitrage. They also depend on traders changing their routing behaviour. Glyph protects
the LP with zero behaviour change required from anyone, and works alongside these systems
rather than competing for the same users.

**vs. permissioned or KYC-gated pools.**
Allowlists achieve protection by destroying permissionlessness, which caps them to
institutional niches. Glyph keeps the pool open to literally everyone, including the bots,
and lets the price do the work. Graded and recoverable beats binary and permanent on both
adoption and fairness.

### The durable advantages

1. **The data moat.** Contracts can be forked in an afternoon; the registry's accumulated
   behavioural history and the live network of pools writing into it cannot. Every day of
   operation widens the gap between Glyph and a fresh fork starting from an empty registry.
2. **Network effects none of the alternatives have.** Every additional pool makes detection
   faster and broader for all pools; every additional reader (lending, perps, RFQ) makes a
   high score more expensive to carry. Single-pool defenses get linearly better at best;
   Glyph compounds.
3. **A primitive, not a feature.** Competitors ship a fee curve. Glyph ships a reputation
   layer whose first consumer is a fee curve. The addressable surface (any protocol that
   prices counterparty risk) is an order of magnitude larger than the hook market alone.
4. **Complementarity as strategy.** Because Glyph occupies an empty axis (identity), every
   "competitor" is actually a potential stack-mate. There is no incumbent it must displace
   to win, which is the cheapest possible adoption path.
5. **Aligned cost structure.** The honest majority pays nothing extra, ever. Defenses that
   spread their cost across all users (volatility fees, auction overhead, routing friction)
   fight their own users; Glyph's cost lands only on extractors, so no constituency pushes
   back on adoption.
6. **First-mover on an inevitable idea.** Identity-priced counterparty risk is how every
   mature market works. Someone will own this primitive on-chain; the registry that gets to
   critical pool mass first becomes the default, and Glyph is live while the idea is still
   uncontested.

## Technology bridges (ecosystem integration, not just usage)

Glyph is also a working demonstration of three ecosystem technologies doing jobs only they
can do — each one load-bearing, none decorative:

- **Uniswap v4 hooks + dynamic fees on Unichain** — the only AMM architecture where
  per-swap, per-identity fee override is possible at all, deployed against Unichain's
  canonical PoolManager. Unichain's one-second blocks are what let the defense land
  mid-attack instead of after it, and its fee economics make a continuously-running keeper
  affordable.
- **Reactive Network** — solves cross-pool (and tomorrow, cross-chain) propagation without
  any off-chain relayer trust: one subscription to the registry covers every pool that
  will ever deploy, aggregation runs off the origin chain at zero gas cost to pools, and
  only threshold crossings travel back as callbacks.
- **Brevis ZK coprocessor** — makes the *history* component of a score trustlessly provable
  rather than attested, the long-term answer to "why should I trust the detector?".
- **Pyth** — first-touch protection for brand-new attackers with no history yet: anomalous
  price impact versus the oracle overrides to max fee instantly.

A reputation layer needs exactly these four legs — programmable fees, event-driven
propagation, provable history, and a real-time price reference. Glyph is what they look like
assembled.
