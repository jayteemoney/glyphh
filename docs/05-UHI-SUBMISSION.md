# 05 — UHI Hookathon: submission fit & judging alignment

This doc maps Glyph onto what the Uniswap Hook Incubator (Atrium Academy, funded by the
Uniswap Foundation) publicly states about its Hookathon: theme, judging panel, submission
shape, and what historically separates winners. Where the cohort portal specifies exact
per-cohort rules (deadlines, video length caps, submission form fields), **verify against
the UHI9 portal before submitting** — those pages are gated to participants; everything
below is synthesized from official public sources (listed at the bottom) plus standard
practice across prior cohorts.

## 1. What the program publicly establishes

- **Format.** The Hookathon is the ~3-week capstone sprint of each cohort; teams are solo or
  pairs; projects are a "capstone hook," self-proposed or drawn from the Request-for-Hooks
  list.
- **Theme.** The hookathon focus is **value leakage** — "creative solutions that protect LPs
  and make volatile-pair liquidity sustainable at low fees."
- **Judges.** Crypto-native VCs (Variant, a16z, Dragonfly, USV) alongside Uniswap
  Foundation/Labs engineers and sponsor teams. Past sponsor prize tracks have included
  **Brevis**, **EigenLayer**, Arbitrum, Circle, Across, Ink, Fhenix and others, each with
  dedicated bounties (e.g. C1: $15k Uniswap Foundation + $5k EigenLayer + $5k Brevis).
- **What winners looked like.** Across cohorts, winning projects clustered on LP pain
  points (57% of all submissions target LP optimization), demonstrated working deployments,
  and showed measurable traction. Example winners: AdaptiveSwap (UHI4 — volatility-reactive
  dynamic fees), FrontrunThis (UHI5 — MEV-aware execution), AlphaEngineHook (UHI6 —
  encrypted strategies).
- **Demo day.** Top projects present live to the judge panel; a short recorded demo video
  (industry norm: judges are not obligated to watch past ~3 minutes) accompanies the
  written submission and repo.

## 2. Theme alignment: Glyph *is* the theme

The brief asks for hooks that stop LP value leakage and keep volatile pairs viable at low
fees. Glyph's mechanism is a point-for-point answer:

| Theme requirement | Glyph's answer |
|---|---|
| Protect LPs | Toxic flow pays up to 10%; the premium is credited to in-range LPs in the same transaction |
| Sustainable at **low fees** | Honest flow keeps 0.30% — protection comes from repricing extractors, not raising everyone's fee |
| Address value leakage at its source | The leak (informed/toxic flow) is identified per-wallet and repriced before it executes |
| Creative / novel | The identity axis is unpriced by every prior hook; cross-pool propagation is unprecedented in this setting |

## 3. Judging-criteria mapping

Hackathon rubrics in this ecosystem consistently weigh innovation, technical execution,
completeness/demo quality, ecosystem impact, and sponsor-tech integration. Glyph's evidence
per dimension — every claim below is reproducible from this repo:

**Innovation / originality.**
First hook to price wallet identity; first to share toxicity state across pools (Reactive)
and to make history ZK-provable (Brevis). The comparison table in
[03 — Ecosystem gap](03-ECOSYSTEM-GAP.md) shows the empty axis it occupies.

**Technical depth & code quality.**
- 69 Foundry tests: unit, fuzz, invariant, and a full end-to-end demo scenario.
- Three trust-separated write paths with real authorization design (EIP-712 + monotonic
  nonces + deadline caps; hook allow-list; Reactive proxy validation).
- Correct v4 mechanics: dynamic-fee override flag, CREATE2 hook-address mining, fee-growth
  premium accounting (with a documented fix of the classic `donate()` double-count/
  `CurrencyNotSettled` trap).
- A working autonomous off-chain system: event-driven keeper, ML scoring, signed
  attestations, replay/rate-limit guards.

**Completeness / working demo.**
Deployed and verified on Unichain Sepolia + Reactive Lasna (addresses + verification txs in
[DEPLOYMENT.md](DEPLOYMENT.md)). Live dashboard. Scripted, rehearsed 3-minute demo
([DEMO_SCRIPT.md](DEMO_SCRIPT.md)) showing the full loop with zero manual intervention:
clean trader at 0.30% → attack burst → autonomous flag in seconds → 5.20% fee → LP donations
ticking up.

**Ecosystem impact.**
A composable registry primitive other protocols can read (lending, perps, RFQ); a network
effect across pools; complementary to (not competitive with) every existing defense.

**Sponsor / partner technology — used structurally, not decoratively.**
Every partner technology in Glyph is load-bearing: remove any one and a named capability
disappears. The two deepest integrations deserve their own treatment.

### Reactive Network: the cross-pool nervous system

Reactive is not an add-on to Glyph; it is the only piece of infrastructure that makes the
project's second core claim ("every pool is a sensor for every other") true without a
trusted relayer. How efficiently it's used:

- **One subscription covers infinity pools.** `GlyphReactive` holds a single subscription —
  to the registry's `ToxicTradeReported` event — rather than one per pool. Because every
  Glyph hook reports into the same registry, every pool that will *ever* deploy is already
  covered by that one subscription. Pool number 500 costs the Reactive layer nothing extra.
  This is O(1) subscription architecture where the naive design is O(n).
- **Aggregation runs off the origin chain.** Severity accumulation per wallet happens in
  the RSC on Lasna, so Unichain pools pay zero gas for cross-pool intelligence. The origin
  chain only ever sees the conclusion: a single callback when a wallet crosses the
  threshold, not a message per toxic trade.
- **The callback path is fully authorized, end to end.** Callback proxy → 
  `GlyphCallbackAdapter` (which validates the canonical proxy and RVM id) → 
  `updateScoreFromReactive`, callable by the adapter alone. The Reactive path can raise a
  score; it cannot touch anything else.
- **Deployed and live, not diagrammed.** The RSC is deployed on Reactive Lasna, funded with
  lREACT, and subscribed to the live registry (address in DEPLOYMENT.md). Origin and
  destination chain IDs are wired for the real deployment. Measured propagation budget:
  flagged in one pool to repriced in all pools in seconds.

### Unichain: the right chain, used for what it's best at

- **Canonical infrastructure, not a sandbox.** Glyph deploys against Unichain's canonical
  v4 PoolManager and canonical Pyth — the hook lives where Uniswap liquidity actually
  lives and composes with everything else deployed there. Judges can verify both swap
  paths on Uniscan from the txs in DEPLOYMENT.md.
- **One-second blocks make the autonomy loop real.** The whole pitch depends on latency:
  a bot must be repriced *during* its attack, not after. On Unichain the measured loop —
  swap lands, keeper sees it, attestation submitted, every subsequent swap repriced — fits
  inside a single attack burst. We demonstrated the flag landing mid-burst, four swaps in.
  On a 12-second chain the same attack would be over before the defense arrived.
- **L2 economics make continuous defense affordable.** The keeper submits attestations as
  ordinary transactions; Unichain's fees are low enough that the entire live verification
  campaign (deploys, liquidity, dozens of swaps, multiple attestations) ran on ~0.01 ETH.
  A defense that costs more than the attack prevents nothing; on Unichain the economics
  work.
- **Aligned by design.** A hook that protects LPs strengthens the chain whose thesis is
  being the home of Uniswap liquidity. Glyph treats Unichain as a partner technology, not
  just a venue.

### Brevis and Pyth

- **Brevis** (recurring UHI sponsor track): ZK circuit + on-chain `GlyphHistoryConsumer`
  make historical toxicity *provable* rather than attested — the trust-minimization path
  for the detector, with a graceful RPC fallback until a proof exists.
- **Pyth**: first-touch anomaly override for brand-new attackers with no history yet —
  anomalous price impact versus the oracle quotes the max fee immediately, and a missing
  or stale feed never reverts a swap.

## 4. Submission checklist

- [ ] **Repo public** with README (pitch, architecture diagram, quickstart, deployments
      table) — ✅ in place; make repo public before the deadline.
- [ ] **3-minute demo video** recorded per [DEMO_SCRIPT.md](DEMO_SCRIPT.md) — script,
      pane layout, prep commands and verified numbers are ready; record with a *fresh*
      attacker wallet for the clean 0 → 8,000 arc.
- [ ] **Project page on the cohort portal**: name, one-liner, description, video link,
      repo link, team members, track selection (Uniswap main + Brevis sponsor track).
      Suggested one-liner: *"Glyph prices each swap by who is trading: wallets earn a
      decaying toxicity score, MEV bots pay up to 33x the base fee, and LPs keep the
      premium — across every pool at once."*
- [ ] **Live deployment addresses** in the submission (judges can verify on Uniscan —
      include the clean-swap and flagged-swap verification txs from DEPLOYMENT.md).
- [ ] **Demo-day presentation**: lead with the live dashboard, run the attack live if
      bandwidth allows, fall back to the recorded video otherwise.
- [ ] **Verify cohort-portal specifics** (exact deadline, video host, form fields,
      eligibility/team declarations) against the UHI9 hackathon page.

## 5. What we tell judges about limitations

Technical judges reward disclosed, scoped limitations and punish discovered ones. Glyph's
three, each with its production path:

1. **Identity = `tx.origin`** (MVP heuristic, openly documented). Production: key reputation
   on `hash(tx.origin, msg.sender)` to resist contract-wrapper reroutes; longer-term,
   stake-weighted attestors.
2. **Demo-grade ML model** (gradient boosting on a synthetic set; price-impact feature
   stubbed). The *pipeline* — features → model → EIP-712 → on-chain — is real and live; the
   model is swappable in one file. Production: train on labeled historical MEV data.
3. **Pyth first-touch auto-flag off in the current deploy** (feeds configured; feature
   gated to Phase 4). The reputation path — the core thesis — does not depend on it.

None of these touch the central claim, which is demonstrated live: **a pool that remembers,
shared by all pools, that pays LPs back.**

## 6. Anticipated judge questions (with answers)

- *"Can't an attacker just rotate wallets?"* — Rotation has a cost: fresh wallets lose
  accumulated approvals/gas/infrastructure, Pyth first-touch catches no-history anomalies,
  `new_wallet_flag` is a model feature, and the production identity hash makes
  wrapper-laundering ineffective. Glyph doesn't need to stop rotation perfectly — it needs
  to make extraction less profitable than the rotation overhead, which a 17–33x fee multiple
  does.
- *"Why would the first pool adopt this?"* — Single-pool value is immediate (repricing +
  LP premium); cross-pool value compounds from pool #2. No cold-start dependency.
- *"Who controls the detector?"* — Today, an allow-listed attestor key (disclosed). The
  design already separates powers (three write paths), decays every score, and has the
  Brevis path for trustless history; stake-weighted attestation is the stated next step.
- *"Is the fee override safe?"* — It uses v4's native dynamic-fee mechanism
  (`OVERRIDE_FEE_FLAG`), capped at 10%, with the premium flowing through standard fee-growth
  accounting — no custom token custody in the hook at all.

## Sources

- [Uniswap Hook Incubator — Atrium Academy](https://atrium.academy/uniswap) (program, judges, capstone format, prizes)
- [Uniswap Foundation: Introducing the Uniswap Hook Incubator](https://www.uniswapfoundation.org/blog/introducing-the-uniswap-hook-incubator) (program funding, structure)
- [UHI 2025 Wrapped — Atrium blog](https://blog.atrium.academy/uniswap-hook-incubator-2025-wrapped) (winner profiles, prize tracks per cohort, submission mix)
- [Hookathon C1 page — LearnWeb3](https://learnweb3.io/hackathons/hookathon-c1/) (prize split incl. Brevis/EigenLayer tracks, judge list, schedule shape)
- Theme statement ("value leakage… protect LPs… sustainable at low fees") — Atrium/UHI hookathon communications.
