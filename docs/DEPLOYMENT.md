# Deployment — Glyph v2

**Live on Unichain Sepolia (chainId 1301), deployed 20 August 2026.**
All contracts verified on Sourcify with `exact_match`.

## Addresses

| Contract | Address | Verified |
|---|---|---|
| `ReputationRegistry` | [`0xbCC750228205f759Adca7289Ce3b4266610b634C`](https://sepolia.uniscan.xyz/address/0xbCC750228205f759Adca7289Ce3b4266610b634C) | exact_match |
| `GlyphHook` | [`0x0B9dDceC50431E147FCcEcFcC4D7D9AE055F80C4`](https://sepolia.uniscan.xyz/address/0x0B9dDceC50431E147FCcEcFcC4D7D9AE055F80C4) | exact_match |
| `RebateVault` | [`0x29735121F2b4389018916574a5E6203f92807E63`](https://sepolia.uniscan.xyz/address/0x29735121F2b4389018916574a5E6203f92807E63) | exact_match |
| `PythPriceOracle` | [`0x65083ff928736453eDbfDe5ECaC5D4d14B025926`](https://sepolia.uniscan.xyz/address/0x65083ff928736453eDbfDe5ECaC5D4d14B025926) | exact_match |
| `SettablePriceOracle` | [`0xb17820Dca51842F8f211F0d340945e1Ef19B7Bc6`](https://sepolia.uniscan.xyz/address/0xb17820Dca51842F8f211F0d340945e1Ef19B7Bc6) | exact_match |
| `GlyphCallbackAdapter` | [`0xd683F42F686CF4b729d5599f6964A0C36e461495`](https://sepolia.uniscan.xyz/address/0xd683F42F686CF4b729d5599f6964A0C36e461495) | exact_match |

Verified source is browsable at
`https://repo.sourcify.dev/1301/<address>` for any address above.

### Canonical infrastructure (not deployed by us)

| | Address |
|---|---|
| PoolManager (v4) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| Pyth | `0x2880aB155794e7179c9eE2e38200202908C17B43` |
| CREATE2 factory | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| Mock GLYPH-A / GLYPH-B | `0x27621742e15B70Cb7794c2fDd4EA25D1b931cA69` / `0xCAF1E314726f650481B634Cc79D4B846cb0c3Aa7` |
| PoolSwapTest router | `0xE145Ba916B2DeA640ad1f0582a90859C1e361267` |

Deployer / attestor: `0x2dfC9aA8580d4634c91f434E3FDBe4688D939f42` (throwaway testnet key).
Total deploy cost: **0.0000039 ETH**.

## Verified on-chain wiring

Read back from chain after deployment, not assumed from the script:

```
hook authorized in registry   true
attestor authorized           true
hook.vault()                  0x29735121F2b4389018916574a5E6203f92807E63
hook.oracle()                 0xb17820Dca51842F8f211F0d340945e1Ef19B7Bc6
vault authorizes hook         true
registry.reactiveProxy()      0xd683F42F686CF4b729d5599f6964A0C36e461495
```

## The hook address encodes its permissions

`0x0B9dDceC…F80C4` ends in `0xC4` = **196** =
`BEFORE_SWAP (128) | AFTER_SWAP (64) | AFTER_SWAP_RETURNS_DELTA (4)`.

v4 derives a hook's permissions from the low bits of its address, so this is not a
coincidence — the salt was mined for it, and `BaseGlyphHook`'s constructor calls
`Hooks.validateHookPermissions`, which would have reverted the deployment had the address
and `getHookPermissions()` disagreed.

**This is why v2 could not reuse the v1 pool.** `AFTER_SWAP_RETURNS_DELTA` is new in v2
(it carries the sandwich rebate), so the v1 hook at `0x8B1b1d36…680c0` is a different
address with different permission bits. Every pool had to be re-initialised.

## Why the demo pool does not price against Pyth

Both oracles are deployed. `PythPriceOracle` is the production adapter: real feeds,
staleness and confidence gates, feed-configured and verified so it can be inspected.

The demo pool, however, is a pair of **mock tokens with no Pyth feed**. Pointing it at the
real ETH/USD and USDC/USD feeds would put the reference near 4000 against a pool
initialised at 1.0 — divergence would saturate and every gap-closing swap would read as
maximally toxic. That is precisely the v1 failure this rebuild exists to fix. So the demo
pool uses `SettablePriceOracle`, seeded at parity, which also lets the demo move the
reference price on camera and show L1 firing live.

The hook cannot tell the two apart; both satisfy `IPriceOracle`. That is what the adapter
seam is for.

## Verification without an explorer API key

Uniscan verification needs an Etherscan v2 API key. Sourcify does not, and produced
`exact_match` for all six contracts — a stronger result than a bytecode-only match, since
it proves the deployed bytecode came from exactly this source and this compiler input.

```bash
ETHERSCAN_API_KEY="" forge verify-contract <addr> <path:Name> \
  --chain-id 1301 --verifier sourcify --verifier-url https://sourcify.dev/server \
  --constructor-args $(cast abi-encode "constructor(...)" ...)
```

Note the blanked key: Foundry auto-loads `.env`, and a present `ETHERSCAN_API_KEY` makes it
default to the Etherscan verifier regardless of `--verifier`.

## Verification transactions

Three transactions a judge can check on Uniscan without running anything. Same pool, same
block window, same 1% divergence between pool and reference price.

| What | Transaction | Result |
|---|---|---|
| Clean flow, pool at reference | [`0x71440314…`](https://sepolia.uniscan.xyz/tx/0x71440314) ×4 | score stays 0, fee **0.300%** |
| Move reference 1% below pool | [`0x676d4268c10555cea60fc3a185cd3cbe500784259d17b193b5791db7ca642fc2`](https://sepolia.uniscan.xyz/tx/0x676d4268c10555cea60fc3a185cd3cbe500784259d17b193b5791db7ca642fc2) | oracle now 0.99e18 |
| **Gap-closing** swap (arbitrage) | [`0x7e6995a11586e53a3457c66fabe67bbac4db9de0231d11ce5db977e6c13ad9d2`](https://sepolia.uniscan.xyz/tx/0x7e6995a11586e53a3457c66fabe67bbac4db9de0231d11ce5db977e6c13ad9d2) | fee **0.846%** |
| **Gap-widening** swap (uninformed) | [`0x18ec04c00a8dbc7a5c8b2dced495a4a4c8eec05299b7d75e3d619a93e4e1d3a5`](https://sepolia.uniscan.xyz/tx/0x18ec04c00a8dbc7a5c8b2dced495a4a4c8eec05299b7d75e3d619a93e4e1d3a5) | fee **0.300%** |

Decoded from the hook's own `FeeQuoted` events:

```
GAP-CLOSING (arbitrage)      base=3000  arb=5460  unproven=0  toxic=0  trustDisc=0  finalFee=8460
GAP-WIDENING (uninformed)    base=3000  arb=0     unproven=0  toxic=0  trustDisc=0  finalFee=3000
```

**This pair is the thesis.** Identical pool, identical divergence, identical size — the only
difference is direction. The swap capturing the divergence pays 0.846%; the swap supplying
uninformed flow pays the base 0.300%. Glyph prices *what the swap does to the pool*, not who
sent it, which is why a fresh wallet cannot rotate out of it.

The arb premium is also exactly what the model specifies, not approximately. Divergence
measured 101 bps; less the 10 bp noise band leaves 91 bps of excess; at `ARB_CAPTURE_PCT = 60`
that is `91 x 60 = 5460`. The number on chain is 5460.

## Cross-pool: Reactive on Lasna

| | |
|---|---|
| `GlyphReactive` (RSC) | `0xCAF1E314726f650481B634Cc79D4B846cb0c3Aa7` on Reactive Lasna (chain 5318007) |
| Funded with | 0.5 lREACT for callback gas |
| Origin / destination chain | 1301 / 1301 |
| Callback proxy (Unichain Sepolia) | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`, authorized on the adapter |

The callback path was verified functionally rather than assumed, by simulating a call from
each side of the authorization boundary:

```
from the authorized proxy      -> succeeds
from an unauthorized address   -> reverts "Authorized sender only"
```

## Sandwich rebate, end to end on testnet

| Step | Result |
|---|---|
| Sandwich staged against the live pool | victim credited **4.8407191260309174** token0 |
| Attacker flagged | toxicity score **5000** |
| Victim claims | balance `1100.0697` -> `1104.9104` token0 |
| After claim | `claimable` 0, vault `outstanding` 0 |

The victim received exactly what was credited, and the vault settled to zero — the surcharge
reached the person the sandwich actually harmed, not the LPs.

### Why the demo bundles three legs into one transaction

A sandwich in the wild is three transactions in one block. Reproducing that against the public
Unichain Sepolia RPC failed for two independent reasons, both recorded here because they are
the kind of thing that eats an afternoon:

1. On one-second blocks the three legs landed **two blocks apart**, so the pattern never formed.
2. The load-balanced RPC served a **stale nonce** (`next nonce 18, tx nonce 17`) and rejected
   the closing leg outright.

`script/SandwichDemo.s.sol` bundles the legs into a single transaction instead. The detection
path is unchanged: `_trackBlock` matches on per-pool *block* state, so three legs in one
transaction and three legs in three transactions traverse identical code. What the bundle buys
is determinism — the legs are guaranteed adjacent and correctly ordered.

The three legs carry three distinct identities through `hookData`, resolved by the hook's
**tier-1 trusted-router path** — the same mechanism a production router uses to let its users
carry their own reputation. Nothing in the hook is special-cased for the demo; it uses a
feature that already exists. Without it all three legs would resolve to one `tx.origin` and the
middle leg would not read as a third party.

## Still outstanding

- **Liquidity** — seeded: 100,000e18 across ticks -6000..6000. Routers:
  `PoolSwapTest 0x4e08F05481fE0be55bF148eca8C7a5D8883b2Bd7`,
  `PoolModifyLiquidityTest 0x51cA6FE978b27a352c0d4eF2185f24aF0aB1f171`.
  Pool id `0x0179ffe588f6dc908f636ecdb3d31ef77d7c3a94e782db3a7f858b03b6c6ce18`.
- Nothing blocking. Frontend still to be pointed at the new deployment.
