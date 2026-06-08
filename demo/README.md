# Glyph Demo Bots

Two viem bots that make the thesis tangible: **the same pool charges toxic flow ~10x more
than honest flow, and routes the difference to LPs.**

| Bot | Behaviour | Outcome |
| --- | --- | --- |
| `attacker_bot.ts` | A tight burst of large, same-direction swaps (MEV / sandwich footprint) | Glyph score climbs → dynamic fee rises toward 10% → premium donated to LPs |
| `clean_trader.ts` | A few small, paced, alternating swaps (ordinary flow) | Glyph score stays 0 → keeps the 0.30% base fee |

Both read the live `ReputationRegistry.scoreOf(wallet)` before/after and print the score
bar + implied fee, so the divergence is visible in the terminal.

## Setup

```bash
cd demo
npm install
cp .env.example .env
# fill in RPC_URL, the two throwaway keys, and the addresses from your deploy
```

**Fastest path (local):** run `anvil`, then
`forge script script/LocalDemo.s.sol --broadcast` from `contract/` — it deploys the whole
stack (PoolManager, tokens, registry/hook/adapter, routers), seeds liquidity, funds anvil
accounts #1/#2, and prints the exact `demo/.env` block to paste here. To flag a wallet
mid-demo, run `script/ScoreWallet.s.sol` (signs the same EIP-712 attestation the detector
would). See the README "Live demo in one command".

For testnet, after `forge script DeployGlyph` + `DeployMockTokens`, run
`script/DemoSetup.s.sol` to add the `PoolSwapTest` router + liquidity, then set:

- `REGISTRY_ADDRESS`, `HOOK_ADDRESS` — from the deploy output
- `SWAP_ROUTER_ADDRESS` — the v4 `PoolSwapTest` router
- `CURRENCY0`, `CURRENCY1`, `TICK_SPACING` — the pool you initialized
- `ATTACKER_PRIVATE_KEY`, `CLEAN_PRIVATE_KEY` — funded testnet keys (and token balances)

## Run

```bash
npm run attacker     # watch the score climb and the fee rise
npm run clean        # watch the score stay flat at the base fee
npm run score        # read-only: print the attacker wallet's current score
```

Run them in two side-by-side terminals during the demo for the clearest contrast.

## Safe by default

If the deploy addresses aren't set yet, the bots **don't** attempt swaps — they print the
current score and exit, so you can wire things up incrementally. Swaps only fire once
`REGISTRY_ADDRESS`, `HOOK_ADDRESS`, and `SWAP_ROUTER_ADDRESS` are all present.

> Use throwaway testnet keys only. These bots sign and send transactions.
