# 02 — The solution: price the swap, not the swapper

Glyph turns the swap fee from a constant into a function of **what the swap does to the pool**.
One sentence:

> **A swap that moves the pool toward the true price is capturing LVR and pays for it; a swap
> that moves the pool away is the uninformed flow LPs want and pays the base rate — at any
> size, from any wallet, with no history required.**

Reputation still exists. It is no longer the defence. It is a discount.

Everything below is deployed and verified on Unichain Sepolia; addresses and transaction
hashes are in [DEPLOYMENT.md](DEPLOYMENT.md).

---

## Why the inversion

Glyph v1 priced swaps on a per-wallet toxicity score. The UHI9 judge found the structural flaw
in one sentence:

> *"You key everything off `tx.origin`, which is better than the router sender but still
> spoofable via fresh wallets… so I'd think about how a sandwicher simply rotating EOAs
> defeats the score."*

That objection is fatal to any design where **the clean state is the default and the default is
free**, because then rotating to a fresh EOA is a complete reset. And no better identity key
fixes it: every key an attacker controls, they can mint more of.

So v2 stops depending on identity for the defence:

| | v1 | v2 |
|---|---|---|
| What sets the fee | the wallet's score | what the swap does to the pool |
| Fresh wallet | free | pays the arbitrage premium on trade #1; pays the unproven premium if large |
| Rotation returns you to | **free** | **unproven** — you forfeit a discount rather than escape a penalty |
| Reputation's role | the whole mechanism | one term of a sum, and the only term that can go *down* |

---

## The three layers

Ordered from identity-free to identity-dependent. The first two cannot be sybilled at all.

### L1 — directional arbitrage premium

Read the pool's real price from `slot0`, read a reference price from an `IPriceOracle`, and
compare. Then ask the question no other fee hook asks: **is this swap closing that gap or
widening it?**

```solidity
divergenceBps = |poolPrice - referencePrice| / referencePrice
closesGap     = (poolPrice > referencePrice) == zeroForOne
```

If it closes the gap, the swap is the arbitrage LPs lose to, and the hook charges **60% of the
gap it closes**, past a 10 bp band left for oracle noise:

```
premium = (divergenceBps - 10) × 60,   capped at 5.00%
```

If it widens the gap, the premium is **exactly zero**. No size threshold, no reputation lookup,
no discretion.

The arithmetic is auditable from the event log. On Unichain Sepolia, with divergence measured
at 101 bps: `(101 - 40) × 60 = 3660`, and 3660 is the number in the `FeeQuoted` event.

| Swap | base | arb | final |
|---|---|---|---|
| [Closes the gap](https://sepolia.uniscan.xyz/tx/0xd4ecdc36bae6b432f7297f2cd3df122c88d1ef5b6ebc98c3618aa1ab8aa7620d) | 3000 | **3660** | **0.666%** |
| [Widens it](https://sepolia.uniscan.xyz/tx/0xd02e2a2e804aff6709eeed971c86f631d44a5cf0c21a5df20834d97514a666ad) | 3000 | 0 | **0.300%** |

Same pool, same divergence, same size, same wallet. Only the direction differs.

### L2 — same-block sandwich surcharge, paid to the victim

Three legs in one block — a wallet opens, a third party trades the same direction into the
worse price, the same wallet reverses — is a sandwich. The hook tracks a sliding two-swap
window per pool per block and prices the closing leg at `MAX_FEE`.

**The surcharge does not go to the LPs.** Only the normally-assembled fee reaches them through
v4's dynamic-fee override. The remainder is taken as a hook delta
(`afterSwapReturnDelta` → `poolManager.take`) and escrowed by address in `RebateVault`, where
the trader in the middle can withdraw it.

This is the part with no precedent. Every other MEV hook that charges a sandwicher more routes
the money to liquidity providers, which leaves the party who was actually harmed exactly as
badly off as before.

Demonstrated on Unichain Sepolia:

```
victim credited     4.840724788897067876 token0
attacker flagged    toxicity 4999
victim claimed      1104.910407 → 1109.751132 token0
after claim         claimable 0, vault outstanding 0
```

### L3 — reputation, as a discount

Three terms, all identity-dependent, and the only place a wallet's history matters:

| Term | Direction | Meaning |
|---|---|---|
| `unproven` | **+** | A large swap from a wallet with no earned trust. Scales with size as a fraction of in-range liquidity; swaps under 0.5% of reserves never pay it, capped at 2.00%. |
| `toxic` | **+** | The detector has flagged this wallet. The v1 curve, unchanged, now one term of a sum. Decays to zero over 7 days. |
| `trustDiscount` | **−** | Earned by settled benign volume over time. Buys the fee down from 0.30% toward a **0.05% floor**. Decays over 30 days. |

Trust is deliberately expensive to earn: `depth × quality × integrity`, a product rather than a
weighted sum, gated on a minimum of ten settled swaps. A product means any factor at zero
zeroes the result — which is why a wallet with no history scores 0 (it has proven nothing, not
that it is suspected of anything) and why a 95%-gap-closing arbitrageur cannot buy trust with
volume alone.

---

## Assembling the fee

```solidity
fee  = BASE_FEE                          // 0.30%
     + arbPremium(divergence, closesGap) // L1, identity-free
     + unprovenPremium(sizeBps)          // L3a, only if trust == 0
     + toxicPremium(score)               // L3b
     - trustDiscount(trust)              // L3c
clamped to [0.05%, 10.00%]
```

Every term is emitted separately:

```
FeeQuoted(poolId, swapper, base=3000, arb=3660, unproven=0, toxic=0, trustDiscount=0, final=6660)
```

That turns "the model is fair" into something any trader can audit line by line — and it gives
the off-chain detector an exact on-chain record of which swaps were uninformed (`arb == 0`),
from one log scan instead of replaying oracle history.

---

## The hot path

`beforeSwap` does one `slot0` read, one oracle view call, two registry view calls, and pure
arithmetic. All intelligence — the model, the trust computation, the cross-pool aggregation —
lives off the critical path. `afterSwap` settles the rebate delta and reports toxicity.

State that must survive from `beforeSwap` to `afterSwap` lives in **EIP-1153 transient
storage** with a per-leg sequence number, so a multi-hop route that touches the same pool twice
does not have its second leg read the first leg's fee. v1 used a persistent mapping keyed
`(poolId, tx.origin)` and had exactly that bug.

---

## Who can write a score

No single component is trusted with the whole system.

| Path | Writer | Authorization |
|---|---|---|
| `updateScore` / `updateTrust` | off-chain detector | EIP-712 from an allow-listed attestor, separate typehashes and nonce sequences, capped deadline |
| `reportToxicSwap` | the pools themselves | `authorizedHook` allow-list, keyed on the real `PoolId` |
| `updateScoreFromReactive` | Reactive Network | the registered proxy adapter only, which itself validates the canonical callback proxy and RVM id |

The detector cannot impersonate a pool, a pool cannot forge an attestation, and the Reactive
path can only ever raise a score.

---

## Cross-pool propagation

`GlyphReactive` on Reactive Lasna holds **one** subscription to the registry's
`ToxicSwapReported` event, so every Glyph pool that will ever deploy is already covered — O(1)
subscriptions where the naive design is O(n). It tracks the **set of distinct pools** a wallet
has been flagged in and propagates only at two or more.

That threshold is the point. A wallet flagged five times in one pool is that pool's local
problem, already priced by its own hook; broadcasting it buys nothing and burns REACT.

---

## What this costs honest traders

Nothing. An ordinary swap that does not close an oracle gap, is not the closing leg of a
sandwich, and is not large relative to the pool pays **0.30%** — the same as it would in any
other pool. A wallet that has proven itself pays as little as **0.05%**.

That is the sustainable-low-fee half of the thesis: not a cheaper pool for everyone, funded by
nobody, but a **0.30% pool that quotes 0.05% to flow that has earned it, funded by what
extractive flow pays.**

See [03 — The ecosystem gap](03-ECOSYSTEM-GAP.md) for how this differs from the directional and
oracle-divergence designs it will be compared against.
