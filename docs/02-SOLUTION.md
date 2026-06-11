# 02 — The solution: reputation-priced liquidity

Glyph turns the swap fee from a constant into a function of the swapper. One sentence:
**every wallet carries a live, decaying toxicity score, and every Glyph pool quotes that
wallet a fee derived from it — with the premium above the base fee paid to LPs in the same
transaction.**

Everything below is **deployed and verified on Unichain Sepolia** (addresses and
verification txs in [DEPLOYMENT.md](DEPLOYMENT.md)).

## The numbers, measured live

| Behaviour | Score | Fee quoted | Multiple vs base |
|---|---|---|---|
| Clean trader (paced, alternating swaps) | 0 | **0.30%** | 1x |
| Flagged MEV-style burst | 8,000 | **5.20%** | ~17x |
| Worst case (score 10,000) | 10,000 | 10.00% | ~33x |

The detector keeper flagged the attacker bot **mid-burst, autonomously, in seconds** — no
human touched anything — and every basis point above 0.30% accrued to in-range LPs via the
pool's fee-growth accounting (`LPDonation` events surface it; 69 Foundry tests cover the
mechanics, including fuzz, invariant and an end-to-end demo scenario).

## How a swap is priced (the hot path)

1. **`beforeSwap`** — the hook reads `registry.scoreOf(tx.origin)`. The registry returns the
   *decay-adjusted* score (see Fairness below). The score maps through a piecewise-linear
   curve (`ToxicityScoring`) to a dynamic LP fee between 0.30% and 10%, applied with v4's
   `OVERRIDE_FEE_FLAG`. A Pyth pull-oracle check can additionally catch anomalous first-touch
   price impact and override to the max fee immediately.
2. **`afterSwap`** — the premium above the base fee has already been credited to in-range
   liquidity by the PoolManager's dynamic-fee accounting; the hook emits `LPDonation` with the
   premium amounts for observability. If the swap was locally toxic, the hook calls
   `registry.reportToxicTrade`, feeding the cross-pool layer.

The hot path adds **one external view call** to the swap. All intelligence lives off the
critical path.

## How a wallet gets a score (three trust-separated write paths)

| Path | Writer | Authorization | Role |
|---|---|---|---|
| `updateScore` | Off-chain ML detector | EIP-712 signature from an allow-listed attestor, strictly-monotonic per-wallet nonce, capped deadline | Behavioral intelligence |
| `reportToxicTrade` | The pools themselves | `authorizedHook` allow-list | Ground-truth, on-chain evidence |
| `updateScoreFromReactive` | Reactive Network callback | Registered `reactiveProxy` (adapter) only, which itself validates the Reactive callback proxy | Cross-pool aggregation |

No single component is trusted with the whole system: the detector can't impersonate a pool,
a pool can't forge an attestation, and the Reactive path is confined to its adapter.

### The autonomous detector (keeper)

A Python keeper watches the v4 PoolManager's `Swap` events for Glyph pools, attributes each
swap to its EOA, and maintains a sliding behavioral window per wallet: inter-swap time gaps
(burstiness), directional pressure (same-direction ratio — the sandwich/arb footprint), and
activity counts. A gradient-boosted classifier plus hard rules produce a score; if it crosses
the threshold, the keeper signs an EIP-712 attestation and submits it — **detection to
on-chain repricing in under ~10 seconds**, with client-side replay and rate-limit guards on
the attestor key.

### Cross-pool propagation (Reactive Network)

`GlyphReactive`, a Reactive Smart Contract on Reactive Lasna, holds **one subscription to the
registry** — which covers every Glyph pool at once, because all hooks report into the same
registry. It aggregates severity per wallet and, past a threshold, dispatches a callback that
raises the wallet's score *everywhere*. An attacker can't pool-hop: every pool is a sensor
for every other pool.

### ZK-proven history (Brevis)

Historical toxicity is provable, not just assertable: a Brevis circuit (Go, deployed
scaffold + on-chain `GlyphHistoryConsumer`) proves a wallet's past `ToxicTradeReported`
events into the detector's feature set. Where no proof exists, the detector falls back to an
RPC event scan — trust-minimization is progressive, not all-or-nothing.

## Fairness: a price, not a blacklist

Scores **decay linearly to zero over 7 days**. Stop the toxic behaviour and the fee returns
to base — observable live on testnet (a wallet flagged at 8,000 read back 7,999 one block
later, and ~5,400 two days later). This single property answers the hardest objections:

- **No permanent punishment** — there is always a path back to 0.30%.
- **Griefing-resistant** — even a falsely-elevated score is temporary and costs the attacker
  an authorized signature or real on-chain toxic behaviour to produce.
- **Economically coherent** — recent behaviour is what predicts the next trade; old sins
  shouldn't price today's flow.

## LP-positive by construction

Toxic flow is not blocked — it is **repriced**. The pool keeps serving every trader, but the
fee curve makes extraction unprofitable and routes the toxicity premium to the people it was
extracted from. LVR stops being a silent tax on LPs and becomes a visible yield line item:
the dashboard tallies `LPDonation` totals live.

## What exists today (honest inventory)

- ✅ Hook, registry, scoring curve, adapter: deployed, 69/69 tests, verified clean + toxic
  paths live on Unichain Sepolia.
- ✅ Autonomous keeper: built, running, verified flagging live (0 → 8,000 mid-burst).
- ✅ Reactive RSC: deployed and funded on Lasna, subscribed to the registry.
- ✅ Live dashboard (Next.js + wagmi): scores, toxic-activity feed, LP-donation tally, with
  historical backfill and live decay.
- ⚠️ Demo-grade ML model (synthetic training set; price-impact feature stubbed) and
  `tx.origin` identity heuristic — both disclosed, with production paths specified in
  [05 — UHI submission fit](05-UHI-SUBMISSION.md#what-we-tell-judges-about-limitations).
