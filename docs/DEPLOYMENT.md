# Deployment — Glyph v2

**Live on Unichain Sepolia (chainId 1301).** Stack deployed 20 August 2026; the hook
redeployed 1 September 2026 to carry the retuned arbitrage tolerance
(see [BACKTEST.md](BACKTEST.md)). All contracts verified on Sourcify with `exact_match`.

## Addresses

| Contract | Address | Verified |
|---|---|---|
| `ReputationRegistry` | [`0xbCC750228205f759Adca7289Ce3b4266610b634C`](https://sepolia.uniscan.xyz/address/0xbCC750228205f759Adca7289Ce3b4266610b634C) | exact_match |
| `GlyphHook` | [`0x34D408062792646fe085d746Fb64AE63435b80C4`](https://sepolia.uniscan.xyz/address/0x34D408062792646fe085d746Fb64AE63435b80C4) | exact_match |
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
hook authorized in registry   true   (and the superseded v2.0 hook revoked -> false)
attestor authorized           true
hook.vault()                  0x29735121F2b4389018916574a5E6203f92807E63
hook.oracle()                 0xb17820Dca51842F8f211F0d340945e1Ef19B7Bc6
vault authorizes hook         true
registry.reactiveProxy()      0xd683F42F686CF4b729d5599f6964A0C36e461495
```

## The hook address encodes its permissions

`0x34D40806…5b80C4` ends in `0xC4` = **196** =
`BEFORE_SWAP (128) | AFTER_SWAP (64) | AFTER_SWAP_RETURNS_DELTA (4)`.

v4 derives a hook's permissions from the low bits of its address, so this is not a
coincidence — the salt was mined for it, and `BaseGlyphHook`'s constructor calls
`Hooks.validateHookPermissions`, which would have reverted the deployment had the address
and `getHookPermissions()` disagreed.

**This is why v2 could not reuse the v1 pool.** `AFTER_SWAP_RETURNS_DELTA` is new in v2
(it carries the sandwich rebate), so the v1 hook at `0x8B1b1d36…680c0` is a different
address with different permission bits. Every pool had to be re-initialised.

**And it is why retuning one constant meant redeploying.** `FlowRisk` is a library inlined
into the hook, so changing `ARB_TOLERANCE_BPS` changes the hook's creation code, which changes
its mined CREATE2 address, which means a new pool. Only the hook moved: the registry keeps its
accumulated scores, the vault keeps its accounting, and the oracles, adapter and routers are
unchanged — so every other address on this page is the one judges were already given.

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

Transactions a judge can check on Uniscan without running anything. Same pool, same block
window, same 1% divergence between pool and reference price. Reproduce the pair with
`forge script script/DirectionalDemo.s.sol`.

| What | Transaction | Result |
|---|---|---|
| Move reference 1% below pool | [`0x26d436a1…84017`](https://sepolia.uniscan.xyz/tx/0x26d436a1f21537387a42bce5e96494c32854afcd224c2a8362b5044116284017) | oracle now 0.99e18 |
| **Gap-closing** swap (arbitrage) | [`0xd4ecdc36bae6b432f7297f2cd3df122c88d1ef5b6ebc98c3618aa1ab8aa7620d`](https://sepolia.uniscan.xyz/tx/0xd4ecdc36bae6b432f7297f2cd3df122c88d1ef5b6ebc98c3618aa1ab8aa7620d) | fee **0.666%** |
| **Gap-widening** swap (uninformed) | [`0xd02e2a2e804aff6709eeed971c86f631d44a5cf0c21a5df20834d97514a666ad`](https://sepolia.uniscan.xyz/tx/0xd02e2a2e804aff6709eeed971c86f631d44a5cf0c21a5df20834d97514a666ad) | fee **0.300%** |

Decoded from the hook's own `FeeQuoted` events:

```
GAP-CLOSING (arbitrage)      base=3000  arb=3660  unproven=0  toxic=0  trustDisc=0  finalFee=6660
GAP-WIDENING (uninformed)    base=3000  arb=0     unproven=0  toxic=0  trustDisc=0  finalFee=3000
```

**This pair is the thesis.** Identical pool, identical divergence, identical size — the only
difference is direction. The swap capturing the divergence pays 0.666%; the swap supplying
uninformed flow pays the base 0.300%. Glyph prices *what the swap does to the pool*, not who
sent it, which is why a fresh wallet cannot rotate out of it.

The premium is exactly what the model specifies, not approximately. Divergence measured
**101 bps**; less the **40 bp** tolerance leaves **61 bps** of real excess; at
`ARB_CAPTURE_PCT = 60` that is `61 x 60 = 3660`. The number on chain is 3660.

Both raw event payloads, if you would rather decode them yourself than trust the table:

```
0x...0bb8  0x...0e4c  0x0  0x0  0x0  0x...1a04     # 3000, 3660, 0, 0, 0, 6660
0x...0bb8  0x0        0x0  0x0  0x0  0x...0bb8     # 3000, 0,    0, 0, 0, 3000
```

## Cross-pool: Reactive on Lasna

| | |
|---|---|
| `GlyphReactive` (RSC) | `0xCAF1E314726f650481B634Cc79D4B846cb0c3Aa7` on Reactive Lasna (chain 5318007) |
| Funded with | 0.5 lREACT · outstanding debt to the system contract: **0** |
| Origin / destination chain | 1301 / 1301 |
| Callback proxy (Unichain Sepolia) | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`, authorized on the adapter |

The callback path was verified functionally from both sides of the authorization boundary:

```
from the authorized proxy      -> succeeds
from an unauthorized address   -> reverts "Authorized sender only"
```

### The subscription, as the network sees it

`rnk_getFilters` on Lasna returns the live filter set. Ours is registered and correctly
configured — chain, contract and topic all match what `GlyphReactive`'s constructor asked for:

```
ChainId : 1301                                                        <- Unichain Sepolia
Contract: 0xbcc750228205f759adca7289ce3b4266610b634c                  <- ReputationRegistry
Topics  : 0xf33e93eccfdd30b4b09621228d3b21882b7b2f3281c62f2e9d303360a7aa69a0
          ( ToxicSwapReported(address,bytes32,uint16,uint256) )
Configs : contract=0xcaf1e314…3aa7  rvmId=0x0…0  active=false
```

Unichain Sepolia is a supported origin chain — 581 other filters are registered against it.

### Origin-side preconditions: now met and checkable

`GlyphReactive` propagates a wallet only once it has been reported toxic in
**`MIN_DISTINCT_POOLS = 2`** different pools. Until 1 September the live deployment had exactly
one Glyph pool, so that condition could not even be *expressed*, let alone met.

`script/CrossPoolDemo.s.sol` stands up a second pool behind the same hook — same tokens, same
registry, `tickSpacing` 30 instead of 60, therefore a different `PoolId` — and has one wallet
make a gap-closing swap in each.

| | Pool A | Pool B |
|---|---|---|
| `PoolId` | `0xb86567cd…555329` | `0xddc5954d…d25a17` |
| tickSpacing | 60 | 30 |
| toxic swap | [`0x7c950aac…bd09e7`](https://sepolia.uniscan.xyz/tx/0x7c950aacf87951bf5869cd2fba6eb94b90c9a733fc837e7d9367ec6425bd09e7) | [`0x229af55d…bc2afe`](https://sepolia.uniscan.xyz/tx/0x229af55d7130d2f3c4626675f1b49e56655ee0fb3b0290209c6fc131d2bc2afe) |
| `ToxicSwapReported` severity | 2622 | 3280 |

Both events carry the same wallet `0x47C6bd75…4C60a` and **different pool ids**, which is exactly
the input the RSC's distinct-pool set counts. Average severity 2951, comfortably over
`DISPATCH_THRESHOLD = 500`.

### Why the callback has not fired: Lasna is halted

The subscription reads `active: false`, and no reactive transaction can execute, because
**Reactive Lasna has stopped producing blocks**:

```
head block   5,699,232
timestamp    2026-09-01 07:25:35 UTC     (frozen; unchanged across repeated polls)
owner nonce  latest 3 / pending 4        <- our subscribe() sits unmined in the mempool
```

The two published Lasna endpoints disagree by roughly 900,000 blocks
(`lasna-rpc.rnk.dev` at 4.81M, `lasna-omni-rpc.rnk.dev` at 5.70M), which is itself a symptom.
The RSC is funded, unpaused, and owes the system contract nothing, so none of the documented
causes of a paused subscription apply.

**This is the one claim in this repository still without a transaction hash behind it, and it is
blocked on an external testnet outage rather than on anything in this codebase.** We would
rather say that plainly than quietly drop the claim.

### Completing it when Lasna resumes

`script/finish-crosspool.sh` does the whole sequence and is safe to re-run — it checks before it
sends, and refuses to spend origin gas if the subscription has not gone active:

```bash
cd contract && ./script/finish-crosspool.sh
```

| Exit | Meaning |
|---|---|
| `0` | The callback fired. The transaction hash is printed; record it here and drop the disclosed gap. |
| `2` | Lasna is still at or below the stall block. Nothing was sent. |
| `3` | Lasna is live but the subscription would not activate. Nothing was sent on the origin chain. |
| `4` | Subscription active and both reports landed, but no callback inside ~7 minutes — check the RSC's REACT balance and debt. |

What it does, in order:

1. **Refuses to proceed while the head is at or below 5,699,232.** A halted chain cannot mine a
   subscription, and broadcasting into one only wastes gas and muddies the record.
2. **Calls `subscribe()` with an explicit 5 gwei priority fee.** The first attempt sat unmined for
   hours because `cast` defaulted the tip to 1 wei; that is worth pinning rather than rediscovering.
3. **Re-runs `CrossPoolDemo`.** Reactive processes events forward from an *active* subscription, so
   the two reports already on chain will not be replayed — they must be emitted again.
4. **Polls the destination chain for `CrossPoolScoreApplied`** on the adapter and prints the
   attacker's resulting registry score.

## Sandwich rebate, end to end on testnet

| Step | Result |
|---|---|
| Sandwich staged against the live pool ([`0x060d7cb3…f54a`](https://sepolia.uniscan.xyz/tx/0x060d7cb38e6346c320be93c964eea9ae9634d09c1c370a6bbb810bc443ffc54a)) | victim credited **4.840724788897067876** token0 |
| Attacker flagged | toxicity score **4999** |
| Victim claims ([`0xd04af4d9…5304`](https://sepolia.uniscan.xyz/tx/0xd04af4d9e6ab6b9679bba2d9d8499176d40921e253bc85847f62986ad9bf5304)) | balance `1104.910407` -> `1109.751132` token0 |
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

- **Liquidity** — seeded: 100,000e18 across ticks -60000..60000. Routers:
  `PoolSwapTest 0x4e08F05481fE0be55bF148eca8C7a5D8883b2Bd7`,
  `PoolModifyLiquidityTest 0x51cA6FE978b27a352c0d4eF2185f24aF0aB1f171`.
  Pool id `0xb86567cd923105facf7c9e0949c7d9cde93f4a3b21114986280c546247555329`.
- **Frontend** — pointed at this deployment and live at
  [glyphh-alpha.vercel.app](https://glyphh-alpha.vercel.app).
- **Second pool** — `0xddc5954d…d25a17`, same hook, tickSpacing 30, liquidity seeded.
- **Known gap, disclosed:** the Reactive cross-pool callback has not fired end-to-end. The
  origin side is now complete and checkable (two distinct pools, two `ToxicSwapReported` events,
  one wallet); the subscription is registered with the correct chain, contract and topic; and
  the RSC is funded and debt-free. It is blocked on Reactive Lasna having halted — see above for
  the evidence and the three commands that finish it once the network resumes.
