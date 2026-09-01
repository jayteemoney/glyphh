# Glyph

**A Uniswap v4 hook that prices a swap by what it does to the pool — not by who sent it.**

Toxic flow pays for the liquidity it consumes. Everyone else gets a cheaper pool than they'd
have without it, and traders who get sandwiched are paid back by the attacker who sandwiched
them.

> **Live app:** [glyphh-alpha.vercel.app](https://glyphh-alpha.vercel.app)
> **Pitch deck:** [twelve slides](https://claude.ai/code/artifact/d897919f-fd0c-4759-a515-84e391cbcd9c)
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
| [Closes the oracle gap](https://sepolia.uniscan.xyz/tx/0xd4ecdc36bae6b432f7297f2cd3df122c88d1ef5b6ebc98c3618aa1ab8aa7620d) (arbitrage) | 3000 | **3660** | **0.666%** |
| [Widens it](https://sepolia.uniscan.xyz/tx/0xd02e2a2e804aff6709eeed971c86f631d44a5cf0c21a5df20834d97514a666ad) (uninformed flow) | 3000 | 0 | **0.300%** |

The swap capturing the divergence — the arbitrage LPs actually lose to — pays 0.666%. The swap
supplying the uninformed order flow LPs *want* pays the base rate. Both are decodable from the
hook's own `FeeQuoted` events by anyone.

The premium is arithmetic, not a fudge factor: divergence measured **101 bps**, less the 40 bp
tolerance leaves **61 bps**, at 60% capture that is **3660**. The number on chain is 3660.

---

## How much it matters

Mechanism is not magnitude, so we measured it. `ai/backtest/lvr.py` replays **30 days of real
ETH/USD** (43,200 minutes of Binance closes) through two identical pools whose only difference
is the fee function.

| | plain 0.30% pool | Glyph pool |
|---|---:|---:|
| gross arbitrage the **pool keeps** | 54.4% | **82.4%** |
| kept by arbitrageurs | $188,209 | **$72,202** |
| total to the pool, 30 days | $856,621 | **$999,895** |

**+$143,274 to LPs over 30 days** on a $10M pool at 0.73× daily turnover — 17.4% of TVL
annualised. The 77–88% capture holds across a 25× range of pool size and a 16× range of flow;
the dollar figure scales with turnover, as all fee revenue does.

And the cost to everyone else, which is the number that decides whether this is worth
deploying: of 86,400 uninformed swaps, **1.05% were misread as arbitrage**. A further 0.44%
paid the unproven-size premium, which is the design working rather than failing. **No swap that
widened the gap paid a premium, at any size, from any wallet** — that one is guaranteed by
construction and fuzz-tested.

The backtest also **found a bug in our own fee model and changed the contract**:
`ARB_TOLERANCE_BPS` shipped at 10 bps, which sits *inside* the pool's 30 bp no-arbitrage band —
a region where no arbitrageur trades, so everything charged there was uninformed flow. It was
taxing 44% of retail swaps. Retuned to 40 bps, that fell to 1.5%, and the hook was redeployed.
Full method, sweep and sensitivity in [`docs/BACKTEST.md`](docs/BACKTEST.md).

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
victim credited     4.840724788897067876 token0
attacker flagged    toxicity 4999
victim claimed      1104.910407 → 1109.751132 token0
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

**Status, stated plainly.** The origin side is live and checkable: a second pool is deployed
behind the same hook, and one wallet has been reported toxic in both — two `ToxicSwapReported`
events, two different pool ids, severities 2622 and 3280. The subscription is registered on
Reactive with the correct chain, contract and topic, and the RSC is funded and owes nothing.
The callback itself has **not** fired, because Reactive Lasna stopped producing blocks on
1 September (head frozen at 5,699,232). This is the one claim here without a transaction hash,
it is blocked on an external outage rather than on this codebase, and
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) carries the evidence and the commands that finish
it.

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
contract/test/                   181 tests: unit, fuzz, invariant, parity export, end-to-end
ai/detector/                     toxicity model, trust model, EIP-712 attestor, keeper
ai/backtest/                     30-day LVR replay against real ETH/USD; the fee model mirrored
                                 and proven equal to the Solidity by ai/tests/test_parity.py
frontend/                        Next.js dashboard: fee decomposition, rebate claim
docs/                            problem, solution, ecosystem gap, backtest, deployment, guide
```

---

## Quickstart

```bash
cd contract
forge install && forge build
forge test              # 181 passing
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
