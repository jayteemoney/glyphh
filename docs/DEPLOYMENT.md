# Glyph — Live Testnet Deployment

**Status:** ✅ Live and verified on testnet (2026-06-08).
Tier 1 (reputation → dynamic fee → LP premium) and Tier 3 (cross-pool Reactive engine) are
both deployed. Clean (0.30%) and toxic (5.20%) swap paths were confirmed on-chain.

This is the single source of truth for contract addresses. Frontend and demo developers should
copy values from here.

---

## 1. Networks

| Network | Chain ID | RPC | Explorer |
|---|---|---|---|
| Unichain Sepolia (origin/destination) | `1301` | `https://sepolia.unichain.org` | https://sepolia.uniscan.xyz |
| Reactive Lasna (RSC host) | `5318007` | `https://lasna-omni-rpc.rnk.dev/` | https://lasna-omni.reactscan.net/ |

Deployer / attestor / RSC owner (testnet, throwaway): `0x2dfC9aA8580d4634c91f434E3FDBe4688D939f42`

---

## 2. Deployed Contracts

### Unichain Sepolia (chainId 1301)

| Contract | Address | Role |
|---|---|---|
| **ReputationRegistry** | `0x1719152d54f265296D31bF2D878C58b65fe01968` | Per-wallet scores; EIP-712 attestations; emits `ScoreUpdated` / `ToxicTradeReported` |
| **GlyphHook** | `0x8B1b1d3640aF4623d4EeF56B1C4f70b9aaA680c0` | v4 hook: reads score → dynamic fee → LP premium; emits `LPDonation` |
| **GlyphCallbackAdapter** | `0xC0Cd92eDdc8e21412B6f10F24d1e2fe98e4f68EC` | Reactive callback landing pad → `updateScoreFromReactive`; registered as registry `reactiveProxy` |
| **MockERC20 (GLYPH-A / token0)** | `0x27621742e15B70Cb7794c2fDd4EA25D1b931cA69` | Pool currency0 |
| **MockERC20 (GLYPH-B / token1)** | `0xCAF1E314726f650481B634Cc79D4B846cb0c3Aa7` | Pool currency1 |
| **PoolSwapTest (swap router)** | `0xE145Ba916B2DeA640ad1f0582a90859C1e361267` | Router the demo bots swap through |
| **PoolModifyLiquidityTest (LP router)** | `0x355d26d96eCba45070f0C767065b61E260839658` | Used to seed liquidity |
| Uniswap v4 PoolManager (canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` | Not deployed by us — Unichain Sepolia canonical |
| Pyth (canonical) | `0x2880aB155794e7179c9eE2e38200202908C17B43` | Not deployed by us — Unichain Sepolia canonical |
| Reactive callback proxy (canonical) | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` | Authorized sender for the adapter |

**Pool:** dynamic-fee pool, `currency0 = token0`, `currency1 = token1`, `fee = DYNAMIC_FEE_FLAG`,
`tickSpacing = 60`, `hooks = GlyphHook`. Initialized at tick 0, seeded with wide-range liquidity.
Pyth feeds configured (ETH/USD, USDC/USD) but local-impact auto-flag is off in this path (Phase 4).

### Reactive Lasna (chainId 5318007)

| Contract | Address | Role |
|---|---|---|
| **GlyphReactive (RSC)** | `0x27621742e15B70Cb7794c2fDd4EA25D1b931cA69` | Subscribes to `ToxicTradeReported` on Unichain, aggregates cross-pool, dispatches score callbacks. Funded with 2 lREACT. |

> The RSC address equals token0's address by coincidence — same deployer + same nonce produces the
> same CREATE address on different chains. They are different contracts on different networks.

**Cross-pool flow:**
`GlyphHook.afterSwap` → `registry.reportToxicTrade` → emits `ToxicTradeReported`
→ Lasna RSC `react()` aggregates → emits `Callback` to chain 1301
→ Unichain callback proxy `0x9299472A…` → `adapter.glyphCallback` (authorized)
→ `registry.updateScoreFromReactive`.

---

## 3. Verification (what was tested live)

| Check | Result |
|---|---|
| `scoreOf(deployer)` fresh | `0` ✅ |
| `isAuthorizedHook(hook)` | `true` ✅ |
| Clean swap (score 0) | fee = `3000` (0.30%), **no** `LPDonation` ✅ ([tx](https://sepolia.uniscan.xyz/tx/0xcf898bdd24c923e1f60b74b9d26f7a019442585aeb9b9ace42267f3592df1ae2)) |
| Flagged swap (score 8000) | fee = `51976` (5.20%), `LPDonation` emitted ✅ ([tx](https://sepolia.uniscan.xyz/tx/0x1e3602368044dac6a8f3e112631ca1a2ed42abaefc06dbbadfa3a77cd888d838)) |
| RSC deployed + funded on Lasna | 2 lREACT, subscribed to registry ✅ |

Score read back as `7999` on the flagged swap — that's the registry's time-decay working live, not a bug.

---

## 4. Frontend integration (`frontend/.env.local`)

Hosted production build: **https://glyphh-alpha.vercel.app** (Vercel, root directory
`frontend`, auto-deploys from `main` with the env vars below).

The dashboard reads three env vars:

```bash
NEXT_PUBLIC_RPC_URL=https://sepolia.unichain.org
NEXT_PUBLIC_REGISTRY_ADDRESS=0x1719152d54f265296D31bF2D878C58b65fe01968
NEXT_PUBLIC_HOOK_ADDRESS=0x8B1b1d3640aF4623d4EeF56B1C4f70b9aaA680c0
```

Then:

```bash
cd frontend && pnpm install && pnpm dev   # → http://localhost:3000/dashboard
```

The dashboard reads `scoreOf`, `ScoreUpdated`, `ToxicTradeReported`, and `LPDonation` directly
from the registry + hook above. No backend needed.

---

## 5. Demo bots (`demo/.env`)

```bash
RPC_URL=https://sepolia.unichain.org
CHAIN_ID=1301
REGISTRY_ADDRESS=0x1719152d54f265296D31bF2D878C58b65fe01968
HOOK_ADDRESS=0x8B1b1d3640aF4623d4EeF56B1C4f70b9aaA680c0
SWAP_ROUTER_ADDRESS=0xE145Ba916B2DeA640ad1f0582a90859C1e361267
CURRENCY0=0x27621742e15B70Cb7794c2fDd4EA25D1b931cA69
CURRENCY1=0xCAF1E314726f650481B634Cc79D4B846cb0c3Aa7
TICK_SPACING=60
# Bot keys (throwaway; fund with a little Unichain Sepolia ETH for gas):
ATTACKER_PRIVATE_KEY=0x...
CLEAN_PRIVATE_KEY=0x...
```

Fund the two bot wallets with mock tokens by re-running `DemoSetup` with `ATTACKER_ADDRESS` /
`CLEAN_ADDRESS` set, or transfer mock tokens from the deployer. Then:

```bash
cd demo && npm install
npx tsx clean_trader.ts          # score stays 0 → 0.30% base fee
# flag the attacker the way the detector would:
cd ../contract
WALLET=<attacker> SCORE=8000 REGISTRY_ADDRESS=0x1719152d54f265296D31bF2D878C58b65fe01968 \
  forge script script/ScoreWallet.s.sol --rpc-url https://sepolia.unichain.org --broadcast --skip-simulation --legacy
cd ../demo && npx tsx attacker_bot.ts   # ~5.2% fee; swaps emit LPDonation
```

---

## 6. Reproducing / re-deploying

All addresses live in `contract/.env` (gitignored). The deploy was run from `contract/` in this order:

```bash
forge script script/DeployMockTokens.s.sol --rpc-url $RPC_URL --broadcast
forge script script/DeployGlyph.s.sol      --rpc-url $RPC_URL --broadcast   # TOKEN_A/B set → also inits pool + Pyth feeds
forge script script/DemoSetup.s.sol        --rpc-url $RPC_URL --broadcast --skip-simulation
# Reactive (Lasna):
forge script script/DeployReactive.s.sol   --rpc-url $LASNA_RPC_URL --broadcast --skip-simulation --legacy
```

Notes for re-deployers:
- **`--skip-simulation`** on `DemoSetup` and the Lasna scripts: Unichain's explorer returns HTML
  (not JSON) for the verification probe, and Lasna isn't an etherscan chain; simulation re-runs
  trip on this. Broadcast still executes normally.
- **`--legacy`** on Lasna (no EIP-1559 fee market there).
- Get lREACT by sending Sepolia L1 ETH to `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`
  (1 ETH → 100 lREACT, max 5 ETH/tx). Then fund the RSC contract directly with lREACT.

---

## 7. Known gaps (not blockers — see HANDOFF.md §6)

- **Detector keeper loop** is not built — scores change only when `ScoreWallet`/the detector CLI is
  run manually. Autonomy work, not deployed infra.
- **Pyth local-impact auto-flag** is off in this deploy (feature returns 0). Phase 4.
- **Brevis** live proof not generated; detector falls back to RPC event scan.
