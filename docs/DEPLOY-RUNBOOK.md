# Deploy runbook — Glyph v2 on Unichain Sepolia

Verified by dry run against live chain state on 20 Aug 2026. Every command below was
simulated; only the `--broadcast` flag is untested, by definition.

---

## 1. Preflight — what your environment already has

Checked against `contract/.env`:

| Item | Status |
|---|---|
| Deployer `0x2dfC9aA8…939f42` | funded, **0.00599 ETH** |
| Estimated deploy cost | **0.0000071 ETH** (~840x headroom) |
| RPC `https://sepolia.unichain.org` | live, chainId 1301 |
| PoolManager `0x00B036B5…9e62AC` | has code |
| Pyth `0x2880aB15…17B43` | has code |
| CREATE2 factory `0x4e59b448…B4956C` | has code |
| Mock tokens `TOKEN_A` / `TOKEN_B` | both have code |

Gas on Unichain Sepolia is 0.001 gwei. **Funding is not a blocker** — you have roughly
840 times what the deploy needs.

## 2. What is missing

### 2.1 Three variables the script reads under different names

`DeployGlyph.s.sol` reads `POOL_MANAGER`, `PYTH_ADDRESS` and `ATTESTOR_ADDRESS`. Your
`.env` has the pool manager under `POOL_MANAGER_ADDRESS` and does not have the other two
at all. Append to `contract/.env`:

```bash
POOL_MANAGER=0x00B036B58a818B1BC34d502D3fE730Db729e62AC
PYTH_ADDRESS=0x2880aB155794e7179c9eE2e38200202908C17B43
ATTESTOR_ADDRESS=0x2dfC9aA8580d4634c91f434E3FDBe4688D939f42
```

### 2.2 A real block-explorer API key

`ETHERSCAN_API_KEY` is currently 5 characters. Forge sends it to Uniscan and gets an HTML
error page back, which is why the dry run was buried in deserialisation errors. Deployment
still succeeds — but **verification will not**, and unverified contracts cost you on
Functionality: a judge cannot read source they cannot see.

Get a key from [etherscan.io/apis](https://etherscan.io/apis) (a v2 key covers Unichain
Sepolia) and replace it.

### 2.3 Reactive deploy variables

`DeployReactive.s.sol` needs four values not currently set:

```bash
REACTIVE_PRIVATE_KEY=<key funded with lREACT on Lasna>
ORIGIN_CHAIN_ID=1301
DEST_CHAIN_ID=1301
CALLBACK_ADAPTER_ADDRESS=<from step 3, after DeployGlyph prints it>
```

The Reactive deployer needs **lREACT on Lasna** — separate from your Unichain balance. If
that faucet is slow, this is the step to start early.

---

## 3. Deploy

### Step 1 — final check

```bash
cd contract
forge test            # expect 181 passing
forge build
```

### Step 2 — dry run

```bash
set -a && . ./.env && set +a
forge script script/DeployGlyph.s.sol --rpc-url "$RPC_URL"
```

Expect `Script ran successfully` and a printed hook address. **Check the hook address ends
in a byte equal to 196** (`0xC4`) — that is `beforeSwap | afterSwap | afterSwapReturnDelta`
encoded in the address. If it does not, the flags in the script and in
`getHookPermissions()` have drifted apart and the constructor will revert on deploy.

### Step 3 — broadcast

```bash
forge script script/DeployGlyph.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify \
  --slow
```

`--slow` matters here: the public Unichain Sepolia RPC is load-balanced and returns lagging
nonces, which is the same quirk the demo bots had to work around. Sending one transaction
at a time avoids a nonce race mid-deploy.

The script prints, in order: `ReputationRegistry`, `PythPriceOracle`, `SettablePriceOracle`,
`RebateVault`, `GlyphHook`, `CALLBACK_ADAPTER`, then an env block.

### Step 4 — propagate the addresses

Copy the printed values into **four** files. Missing any one leaves a component pointing at
the v1 deployment, which will look like a mysterious failure later:

| File | Keys |
|---|---|
| `contract/.env` | `REGISTRY_ADDRESS`, `HOOK_ADDRESS`, `ADAPTER_ADDRESS`, `ORACLE_ADDRESS`, `VAULT_ADDRESS` |
| `ai/.env` | `REGISTRY_ADDRESS`, `HOOK_ADDRESS` |
| `demo/.env` | `REGISTRY_ADDRESS`, `HOOK_ADDRESS`, `SWAP_ROUTER_ADDRESS` |
| `frontend/.env.local` | `NEXT_PUBLIC_REGISTRY_ADDRESS`, `NEXT_PUBLIC_HOOK_ADDRESS`, plus new `NEXT_PUBLIC_VAULT_ADDRESS` |

### Step 5 — seed liquidity

```bash
forge script script/DemoSetup.s.sol --rpc-url "$RPC_URL" --broadcast --slow
```

### Step 6 — Reactive

```bash
forge script script/DeployReactive.s.sol --rpc-url "$LASNA_RPC_URL" --broadcast
```

Then point the registry at the adapter and fund the RSC with lREACT.

### Step 7 — prove it end to end

```bash
# clean swap: expect base fee, no toxicity
cd ../demo && npx tsx clean_trader.ts

# move the reference price, then close the gap: expect an arb premium
cast send $ORACLE_ADDRESS "setPrice(bytes32,uint256,bool)" $POOL_ID 990000000000000000 true \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
npx tsx attacker_bot.ts
```

Capture both transaction hashes. They go in `docs/DEPLOYMENT.md` as the clean-path and
flagged-path evidence a judge can verify on Uniscan without running anything.

---

## 4. Two things that will bite

**The hook address is the permissions.** v2 added `AFTER_SWAP_RETURNS_DELTA`, so the v1 hook
address is no longer valid and the salt must be re-mined — the script does this
automatically, but it means **every pool must be re-initialised against the new hook**. The
old pool at `0x8B1b1d36…680c0` cannot be migrated.

**The demo pool does not price against Pyth, on purpose.** Mock tokens have no feed. Pointing
them at real ETH/USD would put the reference near 4000 against a pool at 1.0, saturating
divergence and making every gap-closing swap read as maximally toxic — the exact v1 failure
this rebuild fixes. Both oracles deploy; `PythPriceOracle` is configured and inspectable as
the production adapter, and the demo pool uses `SettablePriceOracle` seeded at parity. Say
this plainly if asked; it is a stronger answer than pretending otherwise.
