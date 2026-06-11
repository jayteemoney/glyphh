# Glyph — Deployment & Integration Handoff (P2 → P1)

This is the runbook to take Glyph from "code-complete, locally proven" to "live on testnet."
Everything here has been validated end-to-end on a local `anvil` fork.

## TL;DR

- All code is complete. **69 contract tests pass.** The full demo (toxic 5.2% vs clean 0.30%
  fee, with LP donations) runs end-to-end on `anvil`.
- **P1 owns the testnet deploy** — 3 scripts, ~10 minutes, one funded wallet.
- After deploy you get a **working reputation-fee pool + live dashboard** (Tier 1 below).
  Full autonomy (auto-scoring, cross-pool) needs the wiring in §6.

---

## 1. Two bugs already fixed — do not overwrite

While validating the deploy locally, P2 fixed two blocking bugs in P1-owned files. Keep them:

1. **`script/DeployGlyph.s.sol` — CREATE2 hook mining.** `HookMiner.find` now mines against
   the deterministic CREATE2 factory `0x4e59…4956C` (the real deployer of `new{salt}` in a
   broadcast), not the EOA. Before the fix, every deploy reverted with `hook address mismatch`.
2. **`src/GlyphHook.sol` — unfunded `donate()`.** `afterSwap` no longer calls
   `poolManager.donate()`. The dynamic LP fee (`OVERRIDE_FEE_FLAG`) already pays LPs; the extra
   donate double-counted **and** left the hook owing tokens it never settled, reverting every
   high-fee swap with `CurrencyNotSettled`. The `LPDonation` event is kept for observability.
   Regression coverage: `test/DemoScenario.t.sol` (uses the 2-arg `vm.startPrank` so `tx.origin`
   is set — the original tests missed the bug because they pranked only `msg.sender`).

---

## 2. Prerequisites

- Foundry (`forge`, `cast`) installed; submodules pulled (`forge install`).
- A **funded deployer wallet on Unichain Sepolia** (~**0.12 ETH**). Faucets:
  [Unichain docs](https://docs.unichain.org/docs/tools/faucets),
  [QuickNode](https://faucet.quicknode.com/unichain/sepolia),
  [L2Faucet](https://www.l2faucet.com/unichain).
- *(optional, for the live bot demo)* two throwaway bot wallets; fund ~0.02 ETH each, or let
  the deployer forward them gas (`cast send <bot> --value 0.02ether`).

Chain facts: Unichain Sepolia, **chainId 1301**, RPC `https://sepolia.unichain.org`,
explorer `https://sepolia.uniscan.xyz`.

---

## 3. Environment

Create `contract/.env` (gitignored):

```bash
DEPLOYER_PRIVATE_KEY=0x<your funded key>
RPC_URL=https://sepolia.unichain.org
UNICHAIN_SEPOLIA_RPC_URL=https://sepolia.unichain.org
# foundry.toml resolves these even without --verify; dummy is fine for deploy:
ETHERSCAN_API_KEY=dummy
UNICHAIN_SEPOLIA_EXPLORER_URL=https://sepolia.uniscan.xyz
# bot wallets DemoSetup funds with mock tokens (optional):
ATTACKER_ADDRESS=0x<bot1>
CLEAN_ADDRESS=0x<bot2>
```

---

## 4. Deploy (Unichain Sepolia) — 3 commands

Run from `contract/`. Each script prints the addresses the next one needs.

```bash
# 1. Mock tokens  → prints TOKEN_A, TOKEN_B
forge script script/DeployMockTokens.s.sol --rpc-url $RPC_URL --broadcast

# 2. Core stack   → prints ReputationRegistry, GlyphHook, GlyphCallbackAdapter
#    (do NOT set TOKEN_A/TOKEN_B here — skips pool init / Pyth feeds; matches the validated path)
forge script script/DeployGlyph.s.sol --rpc-url $RPC_URL --broadcast

# 3. Liquidity + swap router + bot funding → prints SWAP_ROUTER, CURRENCY0, CURRENCY1
TOKEN_A=0x… TOKEN_B=0x… HOOK_ADDRESS=0x… \
  forge script script/DemoSetup.s.sol --rpc-url $RPC_URL --broadcast
```

Then record the addresses in:
- `README.md` › Deployments table
- `frontend/.env.local` → `NEXT_PUBLIC_REGISTRY_ADDRESS`, `NEXT_PUBLIC_HOOK_ADDRESS`
- `demo/.env` → `REGISTRY_ADDRESS`, `HOOK_ADDRESS`, `SWAP_ROUTER_ADDRESS`, `CURRENCY0`, `CURRENCY1`

**Verify:**
```bash
cast call <REGISTRY> "scoreOf(address)(uint16)" <any addr> --rpc-url $RPC_URL   # → 0
cast call <HOOK> "getHookPermissions()" --rpc-url $RPC_URL                       # beforeSwap+afterSwap true
```

---

## 5. Run the demo

```bash
cd demo && npm install && cp .env.example .env   # paste addresses + bot keys
npx tsx clean_trader.ts          # score stays 0 → 0.30% base fee

# flag the attacker the way the detector would (signs the same EIP-712 attestation):
cd ../contract
WALLET=<bot1> SCORE=8000 REGISTRY_ADDRESS=<REGISTRY> \
  forge script script/ScoreWallet.s.sol --rpc-url $RPC_URL --broadcast
cd ../demo && npx tsx attacker_bot.ts   # now ~5.2% fee; swaps emit LPDonation to LPs
```

Point the dashboard at it: `cd frontend && pnpm install && pnpm dev` → http://localhost:3000/dashboard

---

## 6. Integration state — what's live vs. what needs wiring

Deployment gives you **Tier 1** immediately. Tiers 2–3 are built but not yet autonomous.

### Tier 1 — autonomous on-chain the moment it's deployed ✅
- Every swap reads reputation → dynamic fee → LP premium. No off-chain dependency.
- Dashboard reads scores + `ToxicTradeReported` / `LPDonation` live.
- This is the core product; it is done and proven.

### Tier 2 — built but **manual** (the autonomy gap) ⚠️
- **Detector → registry** works (`python -m detector.run --wallet 0x… --submit` posts a valid
  signed attestation), but nothing runs it automatically. Scores change only when the CLI or
  `ScoreWallet` is run. **Needs a keeper loop** to be autonomous.
- The **ML model is demo-grade**: GradientBoost trained in-memory on 25 synthetic rows, and the
  `price_impact` feature is stubbed to 0. Plausible, not production-trained.

### Tier 3 — built but **never run live** 🔲
- **GlyphReactive (cross-pool aggregation):** not deployed/subscribed; targets deprecated
  **Kopli** — migrate to **Lasna** (chainId `5318007`, RPC `https://lasna-omni-rpc.rnk.dev/`,
  faucet: send Sepolia ETH to `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`, 1 ETH → 100 lREACT).
  `DeployReactive.s.sol`'s chain IDs (1301 origin/dest) are already correct; just deploy against
  the Lasna RPC and fund the RSC.
- **Brevis ZK history:** circuit + `GlyphHistoryConsumer.sol` done; no live proof yet; the
  detector falls back to the RPC event scan when no proof exists.

### Roadmap to "fully functional"

| Phase | Work | Owner | Unlocks | Status |
|---|---|---|---|---|
| 0 (gate) | Deploy §4 | **P1** | Tier 1 live | ✅ done 2026-06-08 (`docs/DEPLOYMENT.md`) |
| 1 | Wire frontend + bots; scripted demo | P2 | Demo-able | ✅ done 2026-06-10 — bots verified live on testnet |
| 2 | Detector **keeper loop** (watch swaps → model → submit) | P2 | Autonomous scoring | ✅ done 2026-06-10 — `ai/detector/keeper.py`, verified live (flagged the attacker bot 0 → 8000 mid-burst) |
| 3 | GlyphReactive on **Lasna** + subscribe + fund | P2/P1 | Cross-pool reputation | ✅ deployed by P1 (2 lREACT, subscribed) |
| 4 *(prod)* | Real price-impact feature + retrain on real MEV; Pyth feeds for on-chain auto-flag; live Brevis proof | P2 | Production-grade | 🔲 open |

Phases 0–3 are live. Phase 4 = production hardening.

---

## 7. Ownership

P2: `ReputationRegistry`, `reactive/*`, `ai/*`, `demo/*`, frontend, `README`, P2 tests, and the
new scripts (`LocalDemo`, `DemoSetup`, `ScoreWallet`). P1: `GlyphHook`, `ToxicityScoring`,
`DeployGlyph`, `foundry.toml`. `interfaces/IReputationRegistry.sol` is frozen (joint PR only).
