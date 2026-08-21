# Glyph

**A Uniswap v4 hook that prices a swap by what it does to the pool — not by who sent it.**

Toxic flow pays for the liquidity it consumes. Everyone else gets a cheaper pool than they'd
have without it, and traders who get sandwiched are paid back by the attacker who sandwiched
them.

> **Live app:** [glyphh-alpha.vercel.app](https://glyphh-alpha.vercel.app)
> **Live on Unichain Sepolia** — every address verified, every claim below reproducible from
> [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).
>
> UHI10 Hookathon · *The Fair Flow Frontier: MEV protection and sustainable low-fee liquidity*

---

## The two transactions that are the whole argument

Same pool. Same 1% divergence between the pool and its reference price. Same size. The only
difference is **direction**:

| Swap | base | arb | final fee |
|---|---|---|---|
| [Closes the oracle gap](https://sepolia.uniscan.xyz/tx/0x7e6995a11586e53a3457c66fabe67bbac4db9de0231d11ce5db977e6c13ad9d2) (arbitrage) | 3000 | **5460** | **0.846%** |
| [Widens it](https://sepolia.uniscan.xyz/tx/0x18ec04c00a8dbc7a5c8b2dced495a4a4c8eec05299b7d75e3d619a93e4e1d3a5) (uninformed flow) | 3000 | 0 | **0.300%** |

The swap capturing the divergence — the arbitrage LPs actually lose to — pays 0.846%. The swap
supplying the uninformed order flow LPs *want* pays the base rate. Both are decodable from the
hook's own `FeeQuoted` events by anyone.

The premium is arithmetic, not a fudge factor: divergence measured **101 bps**, less a 10 bp
noise band leaves **91 bps**, at 60% capture that is **5460**. The number on chain is 5460.

---

## Why v1 was wrong, and what changed

Glyph competed at UHI9 and scored well on substance, but a judge found the structural flaw:

> *"You key everything off `tx.origin`, which is better than the router sender but still
> spoofable via fresh wallets… so I'd think about how a sandwicher simply rotating EOAs
> defeats the score."*

Correct, and unfixable by choosing a better identity key — no key survives an attacker willing
to fund fresh wallets. **The fix is to stop depending on identity for the defence at all.**

v2 prices swaps in three layers, ordered from identity-free to identity-dependent:

| | Layer | Needs identity? |
|---|---|---|
| **L1** | **Directional arbitrage premium.** Compare the pool's real price (`slot0`) to a reference. A swap moving the pool *toward* it is capturing LVR and pays 60% of the gap it closes. A swap moving it *away* is uninformed flow and is never surcharged, at any size, from any wallet. | **No.** Fires on trade #1 of a brand-new wallet. |
| **L2** | **Same-block sandwich surcharge.** Three legs in one block — open, a third party trading the same direction, reverse — is a sandwich. The closing leg pays the max fee, and the surcharge is escrowed **to the victim**. | **No**, within a block. |
| **L3** | **Reputation, as a discount only.** Unknown identities pay a premium scaled by swap size; proven-benign history *earns the fee down*, below base, to a **0.05% floor**. | Yes — but now optional to the defence. |

**Rotating a wallet no longer returns an attacker to free. It returns them to *unproven*,** and
forfeits trust that took settled benign volume to earn. Even if the identity layer is sybilled
completely, L1 and L2 still fire.

That inversion is the headline for LPs too: **a 0.30% pool that quotes 0.05% to flow which has
proven itself, funded by what extractive flow pays.**

---

## The sandwich rebate

Most MEV hooks stop at charging the attacker more — which routes the money to LPs. But the party
a sandwich harms is the **trader squeezed between the two legs**, not the LP. Paying LPs leaves
the actual victim exactly as badly off.

So the closing leg is priced at `MAX_FEE` in total, but only the normally-assembled part reaches
LPs through v4's dynamic fee override. The remainder is taken as a hook delta
(`afterSwapReturnDelta` → `poolManager.take`) and escrowed to the victim by address.

Demonstrated on Unichain Sepolia:

```
victim credited     4.8407191260309174 token0
attacker flagged    toxicity 5000
victim claimed      1100.0697 → 1104.9104 token0
after claim         claimable 0, vault outstanding 0
```

---

## Every pool is a sensor for every other

A `GlyphReactive` smart contract on Reactive Lasna holds **one** subscription to the registry's
`ToxicSwapReported` event — so every Glyph pool that will ever deploy is already covered. It
tracks the **set of distinct pools** a wallet has been flagged in, and propagates cross-pool only
at two or more.

That threshold is the point. A wallet flagged five times in one pool is that pool's local problem,
already priced by its own hook; broadcasting it buys nothing and burns REACT. v1 could not tell
pools apart at all — the hook passed its own address where the pool ID belonged — so "cross-pool"
was really "repeat offences somewhere". Now it means what it says, and there are tests for both
directions.

---

## Architecture

```
                    off-chain detector ── EIP-712 ──┐
        features → toxicity model                   │  updateScore
                 → trust model (depth × quality)    │  updateTrust
                                                    ▼
   ┌───────────────────── Unichain Sepolia ──────────────────────┐
   │                                                              │
   │   swap ──▶ GlyphHook.beforeSwap                              │
   │              ├── IPriceOracle ─▶ divergence + direction  L1  │
   │              ├── slot0 / liquidity ─▶ size                   │
   │              ├── registry.scoreOf / trustOf              L3  │
   │              └── block state ─▶ sandwich?                L2  │
   │                     │                                        │
   │                     ▼  fee | OVERRIDE_FEE_FLAG               │
   │              GlyphHook.afterSwap                             │
   │                     ├── take() ─▶ RebateVault ─▶ victim      │
   │                     └── reportToxicSwap ─▶ ReputationRegistry│
   └──────────────────────────┬───────────────────────────────────┘
                              │ ToxicSwapReported
                              ▼
              ┌──── Reactive Lasna ────────────────────┐
              │ GlyphReactive: one subscription,       │
              │ distinct-pool set, callback at 2+ pools│
              └────────────────────────────────────────┘
```

### Repository layout

```
contract/src/
  GlyphHook.sol                  the hook — identity, divergence, fee, sandwich, rebate
  base/BaseGlyphHook.sol         IHooks base; validates permissions against its own address
  libraries/FlowRisk.sol         the fee model, pure functions
  libraries/SwapGuard.sol        EIP-1153 transient state, per-leg
  ReputationRegistry.sol         toxicity (7d decay) + trust (30d decay), EIP-712
  RebateVault.sol                escrow for sandwich victims
  oracles/                       PythPriceOracle (production) · SettablePriceOracle (demo)
  reactive/                      GlyphReactive (RSC) + GlyphCallbackAdapter
contract/test/                   157 tests: unit, fuzz, invariant, end-to-end
ai/detector/                     toxicity model, trust model, EIP-712 attestor, keeper
frontend/                        Next.js dashboard: fee decomposition, rebate claim
docs/                            deployment, runbook, user guide, demo script
```

---

## Quickstart

```bash
cd contract
forge install && forge build
forge test              # 157 passing
```

Run the whole stack locally, including the layers the testnet demo shows:

```bash
anvil &                                                   # terminal 1
cd contract && DEPLOYER_PRIVATE_KEY=0xac09…ff80 \
  forge script script/LocalDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

`LocalDemo` deploys the PoolManager, tokens, registry, hook, vault and a settable oracle, seeds
liquidity, and funds the bots. See [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md) for the full path
from a cold clone to a claimed rebate.

---

## What we tell you before you find it

Disclosed limitations, each with its production path:

1. **Identity is still a heuristic.** Three tiers — a trusted router naming the user in
   `hookData`, then a self-registered smart account, then `tx.origin`. Under ERC-4337
   `tx.origin` is the *bundler*, so v1 scored the bundler and every user of one bundler shared a
   reputation; tier 2 fixes that for accounts that unlock the PoolManager themselves, and routed
   4337 accounts need tier 1. **This is why reputation is only a discount** — a wrong identity
   costs an honest trader a discount they earned, it does not let an extractive swap through.

2. **Sandwich detection has a bounded false positive.** A trader reversing their own position
   while an unrelated trade lands in between is indistinguishable on-chain from a sandwich and is
   charged as one. Named and tested as `test_knownFalsePositive_selfReversalAroundUnrelatedFlow`.
   The cost is a surcharge on one leg, not a block or a ban, and the "victim" who receives it did
   really trade at the worse price. The alternative requires observing intent.

3. **`_sizeBps` approximates in-range reserves** as `L / sqrtP`. Concentrated positions hold
   less, so this overstates the reserve and *understates* size — conservative in the only
   direction that matters: it can quote too low a premium, never surcharge an honest trader.

4. **The demo pool does not price against Pyth, deliberately.** Its tokens are mocks with no
   feed; pointing them at real ETH/USD would put the reference near 4000 against a pool at 1.0,
   saturating divergence and making every gap-closing swap read as maximally toxic — the exact v1
   failure this rebuild fixes. `PythPriceOracle` is deployed and verified as the production
   adapter; the demo pool uses `SettablePriceOracle`. The hook cannot tell them apart.

---

## Provenance

Glyph v1 competed in UHI9. **v2 is the work in this repository since 17 August 2026**, and the
diff against commit `31c6cbb` is the submission.
[`docs/UHI10-CHANGELOG.md`](docs/UHI10-CHANGELOG.md) maps every change to the judging criterion
it serves, including the mistakes made along the way and how they were corrected.

## Tech

Uniswap v4 · EIP-1153 transient storage · Pyth · Reactive Network · OpenZeppelin · Foundry ·
Next.js + wagmi + viem · Python (scikit-learn, web3.py)

## License

MIT
