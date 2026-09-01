# User guide

End to end: from a cold clone to a claimed sandwich rebate. Two paths — **local**, which needs
nothing but Foundry and shows every layer, and **live testnet**, which needs no install at all.

---

## Path A — no install: use the live deployment

1. Open **[glyphh-alpha.vercel.app](https://glyphh-alpha.vercel.app)** and connect a wallet on
   Unichain Sepolia (chain 1301).
2. The dashboard shows:
   - **Your wallet** — toxicity, earned trust, and the fee an ordinary swap would cost you.
   - **Sandwich rebate** — what the vault owes you, and a button to withdraw it.
   - **Why each swap was priced** — every recent swap with its fee broken into terms.
   - **Wallet reputation** — toxicity, trust, and how many *distinct* pools each wallet has been
     flagged in. Two or more is the threshold at which the cross-pool layer propagates.

Nothing is simulated. Everything is read from the contracts listed in
[`DEPLOYMENT.md`](DEPLOYMENT.md).

### Verify the central claim without trusting the UI

Two transactions, same pool, same divergence, opposite directions:

```bash
cast receipt 0xd4ecdc36bae6b432f7297f2cd3df122c88d1ef5b6ebc98c3618aa1ab8aa7620d \
  --rpc-url https://sepolia.unichain.org   # closes the gap  -> 0.666%
cast receipt 0xd02e2a2e804aff6709eeed971c86f631d44a5cf0c21a5df20834d97514a666ad \
  --rpc-url https://sepolia.unichain.org   # widens it       -> 0.300%
```

Decode the `FeeQuoted` event in each and compare the `arb` term. One is 3660, the other is 0.

Or reproduce the pair yourself against the live pool:

```bash
cd contract
forge script script/DirectionalDemo.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --broadcast --slow
```

It moves the reference 1% below the pool, swaps once in each direction, and the two
`FeeQuoted` events tell you the rest.

---

## Path B — local: run the whole stack

### 1. Build and test

```bash
git clone https://github.com/jayteemoney/glyphh && cd glyphh/contract
forge install
forge build
forge test              # 181 passing
forge coverage --ir-minimum --no-match-coverage "(test|script)"   # 94% lines
```

### 2. Bring up the stack

```bash
anvil &                                                    # terminal 1

cd contract                                                # terminal 2
# Anvil's default account #0 — a published test key, funded only on your local node.
DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/LocalDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

It prints an env block: registry, hook, vault, oracle, router, both tokens. Copy it into
`demo/.env`.

`LocalDemo` uses `SettablePriceOracle` rather than Pyth, because mock tokens have no feed — and
because a reference price you can *move* is what lets you watch L1 fire.

### 3. Watch a clean trader keep the base fee

```bash
cd ../demo && npm install && npx tsx clean_trader.ts
```

Four paced swaps. Score stays 0, fee stays 0.300%. The pool is at its reference, so no layer
has anything to charge for.

### 4. Watch the arbitrage premium fire — L1

Move the reference 1% below the pool, then close the gap:

```bash
cast send $ORACLE_ADDRESS "setPrice(bytes32,uint256,bool)" $POOL_ID 990000000000000000 true \
  --private-key $DEPLOYER_PRIVATE_KEY --rpc-url http://127.0.0.1:8545

npx tsx attacker_bot.ts
```

The fee jumps to **0.666%**. **Then swap the other way and it stays at 0.300%** — same pool,
same divergence, same size, same wallet. That contrast is the mechanism: Glyph charges for
closing the gap, never for widening it.

The 1% is chosen so the gap clears the 40 bp tolerance. Try `0.998e18` instead (20 bps of
divergence) and *neither* direction is surcharged — that is deliberate, and
[BACKTEST.md](BACKTEST.md) explains why the threshold sits where it does.

### 5. Watch a sandwich pay its victim — L2

```bash
cd ../contract
forge script script/SandwichDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Three legs — attacker opens, a third party trades the same direction, attacker reverses — and
the closing leg is surcharged. It prints what the victim is owed.

The legs are bundled into one transaction on purpose. Detection matches on per-pool *block*
state, so one transaction and three traverse identical code; the bundle only guarantees they are
adjacent and correctly ordered, which three separate transactions could not on a public RPC.

Claim it as the victim:

```bash
cast send $VAULT_ADDRESS "claim(address)" $CURRENCY0 \
  --private-key $CLEAN_PRIVATE_KEY --rpc-url http://127.0.0.1:8545
```

### 6. Watch reputation move — L3

```bash
cd ../ai
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

python -m detector.run --wallet 0xABCD… --verbose            # toxicity, with features
python -m detector.run --wallet 0xABCD… --trust --verbose    # earned trust, with the breakdown
python -m detector.run --wallet 0xABCD… --trust --submit     # sign and submit on chain
```

The trust breakdown prints depth and quality separately. A wallet with no history scores 0 — not
because it is suspected of anything, but because it has proven nothing. That is the point.

Run the keeper to close the loop with no human in it:

```bash
python -m detector.keeper
```

### 7. Reproduce the backtest

The claim that Glyph returns 82% of gross arbitrage to LPs, against 54% for a plain pool, is
not a brochure number — it is a script, and it takes about a minute to re-derive.

```bash
cd ai/backtest
python3 fetch.py 30        # 30 days of real ETH/USD, 1-minute, no API key needed
python3 lvr.py             # the headline table
python3 sweep.py           # the tolerance sweep that changed the contract
python3 sensitivity.py     # nine parameter combinations, to see what survives
```

The Python fee model is a mirror of `FlowRisk.sol`. To convince yourself it has not drifted:

```bash
cd contract && forge test --match-contract FlowRiskParity   # exports 2,500 vectors from the EVM
cd ../ai && python -m pytest tests/test_parity.py           # asserts every one of them
```

See [BACKTEST.md](BACKTEST.md) for what the numbers mean and what the simulation does *not*
model.

### 8. See it in the dashboard

```bash
cd ../frontend
pnpm install
cp .env.example .env.local     # paste the addresses from step 2
pnpm dev                       # http://localhost:3000/dashboard
```

---

## Reading a fee

Every swap emits `FeeQuoted` with each term separate:

```
base=3000  arb=3660  unproven=0  toxic=0  trustDiscount=0  finalFee=6660
```

| Term | What it means | How to avoid it |
|---|---|---|
| `base` | The pool's ordinary fee, 0.30%. | — |
| `arb` | You closed a gap between the pool and its reference, and the gap was wider than 40 bps. | Don't arbitrage this pool, or accept that LPs keep 60% of the excess. Inside 40 bps you are never charged, in either direction. |
| `unproven` | A large swap from a wallet with no record. Small swaps never pay this. | Build history, or trade smaller relative to liquidity. |
| `toxic` | The detector has flagged this wallet. Decays to zero over 7 days. | Stop. It fades on its own. |
| `trustDiscount` | Subtracted. Earned by settled benign volume over time. | Keep supplying uninformed flow. Decays over 30 days. |

The terms always sum to `finalFee`, clamped to `[0.05%, 10%]`. There is a test asserting it.

---

## Troubleshooting

**"No activity yet" on the dashboard.** The public RPC caps `eth_getLogs` and returns HTTP 400
rather than truncating. The reader chunks around this, but a stricter provider may need
`NEXT_PUBLIC_BACKFILL_BLOCKS` lowered.

**`PoolAlreadyInitialized` (`0x7983c051`) during a script.** The pool exists; the script should
be checking `getSlot0` before initializing rather than wrapping it in try/catch — a try/catch is
idempotent in simulation but still records the call for broadcast.

**`nonce too low` on the public RPC.** It is load-balanced and replicas lag. Use `--slow`, or
retry.

**Hook deployment reverts.** The hook's address encodes its permissions. If the mined flags and
`getHookPermissions()` disagree, `BaseGlyphHook`'s constructor rejects the deployment — by
design. v2 needs `beforeSwap | afterSwap | afterSwapReturnDelta`, so the address must end in a
byte equal to **196**.

**A swap you expected to be surcharged wasn't.** The arbitrage premium only fires above **40
bps** of divergence. That threshold is not arbitrary: below the base fee of 30 bps, closing the
gap does not cover the fee, so there is no arbitrage there to charge for — only uninformed flow
that happens to move the right way. See [BACKTEST.md](BACKTEST.md).

**`forge coverage` fails with "Stack too deep".** Coverage disables the optimizer. Add
`--ir-minimum`.
