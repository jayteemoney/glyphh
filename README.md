# Glyph

**The first Uniswap v4 hook that prices each swap by *who* is trading, not just what.**

Glyph assigns a reputation score to every wallet from its on-chain trading history. Swaps from clean
traders pay the standard 0.30% fee. Swaps from wallets with a toxic history — sandwichers,
arbitrageurs, MEV bots — pay up to 10%, with the **excess donated directly back to LPs**. A wallet
flagged in one pool is guarded against in *every* Glyph pool within seconds.

> **Live app: [glyphh-alpha.vercel.app](https://glyphh-alpha.vercel.app)** — connect a wallet
> and watch the registry stream in real time.
>
> UHI9 / Atrium hookathon submission.
> **Full written case — problem, solution, ecosystem gap, positioning, and UHI judging
> alignment — in [`docs/`](docs/README.md).**

---

## The problem

Passive AMM LPs are adversely selected. Arbitrageurs and sandwichers extract value on every block —
this is **LVR (loss-versus-rebalancing)**, the central economic drag on AMM liquidity. Existing
defensive hooks react to *price* (DetoxHook) or *volatility* (AdaptiveSwap): they see the swap, never
the swapper. So the same MEV bot pays the same fee as a retail trader, and re-attacks pool after pool.

## The Glyph difference

| Hook | Reacts to |
|---|---|
| DetoxHook | Price divergence (Pyth) |
| AdaptiveSwap | Volatility |
| **Glyph** | **The trader — wallet reputation + cross-pool propagation** |

Two axes nobody else prices:

1. **Who, not what.** A credit score for wallets. Reputation comes from an off-chain ML detector,
   signed as an EIP-712 attestation, plus on-chain toxic-trade reports and ZK-proven history.
2. **Every pool is a sensor for every other.** A Reactive Smart Contract aggregates toxicity across
   pools and propagates an elevated score back to the registry, so an attacker can't pool-hop.

And it's **fair**: scores **decay linearly to zero over 7 days**. Stop being toxic and you recover —
no permanent blacklist, no griefing.

---

## Architecture

```
            ┌──────────── off-chain (detector) ────────────┐
            │ features.py (RPC + Brevis) → model.py (ML) →  │
            │ attestor.py (EIP-712 sign) → run.py (submit)  │
            └───────────────────────┬───────────────────────┘
                                    │ updateScore(attestation)
                                    ▼
   ┌──────────────────── Unichain Sepolia ─────────────────────┐
   │  Pool A ─beforeSwap─┐                  ┌─beforeSwap─ Pool B │
   │                     ▼                  ▼                    │
   │              ┌──────────────  ReputationRegistry ────────┐ │
   │  reportToxicTrade ─▶  score store · EIP-712 · decay      │ │
   │              └────┬─────────────────────────▲────────────┘ │
   │   ToxicTradeReported                  updateScoreFromReactive
   │                   │                         │ (via GlyphCallbackAdapter)
   └───────────────────│─────────────────────────│──────────────┘
                       │ subscribe               │ Callback
                       ▼                         │
            ┌──────────── Reactive Network (Kopli) ───────────┐
            │  GlyphReactive (RSC): subscribe → aggregate →   │
            │  emit Callback once a wallet crosses threshold  │
            └─────────────────────────────────────────────────┘
```

### Lifecycle of a swap

1. **beforeSwap** — the hook reads `registry.scoreOf(tx.origin)` (decay-adjusted) and sets a dynamic
   fee on the `ToxicityScoring` curve. A Pyth pull-oracle check catches anomalous first-touch price
   impact and overrides to the max fee immediately.
2. **afterSwap** — fee charged above the 0.30% base is `donate()`d to LPs; a locally-toxic swap emits
   `ToxicTradeReported`.
3. **Cross-pool** — `GlyphReactive` on the Reactive Network has one subscription to the registry
   (covering *all* pools). It aggregates severity per wallet and, past a threshold, emits a
   `Callback` that the `GlyphCallbackAdapter` forwards to `updateScoreFromReactive` — raising the
   wallet's score everywhere within ~5–10s.
4. **Decay** — with no fresh toxicity, the score linearly returns to zero over 7 days.

### Three trust-separated write paths

| Path | Caller | Auth |
|---|---|---|
| `updateScore` | off-chain ML detector | EIP-712 sig from an authorized attestor + monotonic nonce |
| `reportToxicTrade` | Glyph hooks | `authorizedHook` allow-list |
| `updateScoreFromReactive` | Reactive callback | `reactiveProxy` (the adapter) only |

---

## Repository layout

```
contract/        Foundry project
  src/
    GlyphHook.sol                   v4 hook — dynamic fee, Pyth, LP donation   (P1)
    libraries/ToxicityScoring.sol   pure score → fee curve                    (P1)
    ReputationRegistry.sol          score store · EIP-712 · 7-day decay        (P2)
    reactive/GlyphReactive.sol      Reactive Smart Contract (cross-pool)       (P2)
    reactive/GlyphCallbackAdapter.sol  Reactive → registry bridge              (P2)
    interfaces/IReputationRegistry.sol  frozen hook ↔ registry seam
  test/          69 tests (unit, fuzz, invariant, end-to-end demo scenario)
  script/        DeployGlyph (origin) · DeployReactive (Kopli) · LocalDemo (anvil)
                 DemoSetup (liquidity+router) · ScoreWallet (manual attestation)

frontend/        Next.js + wagmi + viem live dashboard
  src/app/dashboard   score table · live toxic feed · LP-donation tally
  src/app/pools       cross-pool pool list

demo/            viem bots — attacker (toxic burst) vs clean trader

ai/
  detector/      Python ML detector (features → score → EIP-712 attestation)
                 keeper.py — autonomous loop: watch swaps → score → auto-submit
  brevis/        Brevis ZK circuit (Go) + on-chain consumer for proven history
```

---

## Quickstart

### Contracts

```bash
cd contract
forge install            # forge-std, OpenZeppelin, v4-core/periphery, reactive-lib
forge build
forge test -vv           # 69 passing
```

### Live demo in one command (local)

Spin up the entire stack on `anvil` and watch a toxic wallet price itself out while a
clean trader keeps the base fee — the whole thesis, end-to-end, no testnet needed:

```bash
anvil &                                                   # terminal 1

cd contract                                               # terminal 2
DEPLOYER_PRIVATE_KEY=0xac09…ff80 \
  forge script script/LocalDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
# → prints REGISTRY_ADDRESS / HOOK_ADDRESS / SWAP_ROUTER_ADDRESS / CURRENCY0 / CURRENCY1

cd ../demo && npm install && cp .env.example .env         # paste the addresses above
npx tsx clean_trader.ts        # score stays 0  → 0.30% base fee
npx tsx attacker_bot.ts        # baseline: score 0 → base fee

# simulate the detector flagging the attacker, then swap again:
cd ../contract
WALLET=0x7099…79C8 SCORE=8000 REGISTRY_ADDRESS=0x… DEPLOYER_PRIVATE_KEY=0xac09…ff80 \
  forge script script/ScoreWallet.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd ../demo && npx tsx attacker_bot.ts   # now 5.2% fee, swaps emit LPDonation to LPs
```

`LocalDemo.s.sol` deploys PoolManager, two mock tokens, the registry/hook/adapter, the v4
test routers, seeds liquidity, and funds the bot wallets — see `demo/README.md`.

### Frontend dashboard

Hosted: **https://glyphh-alpha.vercel.app** (auto-deploys from `main`). To run locally:

```bash
cd frontend
pnpm install
cp .env.example .env.local   # set NEXT_PUBLIC_REGISTRY_ADDRESS / NEXT_PUBLIC_HOOK_ADDRESS
pnpm dev                     # http://localhost:3000/dashboard
```

### Off-chain detector

```bash
cd ai
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m detector.run --wallet 0xABCD... --verbose         # dry run, prints attestation
python -m detector.run --wallet 0xABCD... --submit          # sign + submit on-chain
```

### Autonomous keeper (detector loop)

The keeper closes the loop: it watches the v4 PoolManager for swaps in the Glyph pool,
scores each active wallet (ML model + a directional-burst rule), and auto-submits a signed
attestation the moment behaviour turns toxic — no human in the loop:

```bash
cd ai
cp .env.example .env         # fill addresses from docs/DEPLOYMENT.md + attestor key
python -m detector.keeper    # leave running; flags toxic wallets within seconds
```

---

## Deployments

Live on testnet — full details, pool parameters, and verification txs in
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

| Contract | Network | Address |
|---|---|---|
| ReputationRegistry | Unichain Sepolia | `0x1719152d54f265296D31bF2D878C58b65fe01968` |
| GlyphHook | Unichain Sepolia | `0x8B1b1d3640aF4623d4EeF56B1C4f70b9aaA680c0` |
| GlyphCallbackAdapter | Unichain Sepolia | `0xC0Cd92eDdc8e21412B6f10F24d1e2fe98e4f68EC` |
| MockERC20 GLYPH-A / GLYPH-B | Unichain Sepolia | `0x2762…cA69` / `0xCAF1…3Aa7` |
| PoolSwapTest router | Unichain Sepolia | `0xE145Ba916B2DeA640ad1f0582a90859C1e361267` |
| GlyphReactive (RSC) | Reactive Lasna | `0x27621742e15B70Cb7794c2fDd4EA25D1b931cA69` |
| Brevis verifier app | — | `TBD` (circuit built, no live proof yet) |

---

## LP-positive by design

Every basis point above the 0.30% base fee charged to toxic flow is donated to LPs in the same
transaction via `PoolManager.donate()` — it accrues to in-range liquidity without moving the price.
Toxic flow stops being a tax on LPs and becomes a *yield source*.

## Security notes

- **Identity:** the MVP keys reputation on `tx.origin`. This is a soft heuristic, not authorization —
  disclosed openly. Production path: hash `(tx.origin, msg.sender)` to resist contract-wrapper reroutes.
- **Replay:** EIP-712 attestations use strictly-monotonic per-wallet nonces and a capped deadline window.
- **Reactive auth:** `updateScoreFromReactive` is callable only by the registered `reactiveProxy`
  (the adapter), which itself validates the Reactive callback proxy and RVM id.
- **Oracle safety:** a missing/stale/low-confidence Pyth update is skipped, never reverting the swap.
- **Fairness:** linear 7-day decay prevents permanent penalties and griefing.

## What's next

Sybil-resistance v2 (`(tx.origin, msg.sender)` identity + stake-weighted attestors), multi-chain
propagation, a shared cross-protocol reputation layer, and an LP-facing analytics subgraph.

## Tech stack

Uniswap v4 · Pyth Network · Reactive Network · Brevis ZK coprocessor · OpenZeppelin (EIP-712, ECDSA,
Ownable) · Next.js + viem + wagmi · Foundry.

## License

MIT
