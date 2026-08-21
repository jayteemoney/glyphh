# Demo script — three minutes

Recorded in your own voice, screen captured, no slides read aloud. The rubric marks down
AI-produced presentations and rewards demonstrating genuine understanding of the code, so the
goal throughout is **show, then explain in your own words** — never narrate a static page.

**Total: 2:55.** Rehearse until you can hit the beats without reading. Record at least three
takes; the fourth is always better than the first.

---

## Before you record

```bash
# 1. Local stack, so nothing depends on a public RPC mid-take
anvil &
cd contract && DEPLOYER_PRIVATE_KEY=0xac09…ff80 \
  forge script script/LocalDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# 2. Paste addresses into demo/.env and frontend/.env.local
# 3. Frontend up at localhost:3000/dashboard, wallet connected
# 4. forge test in a spare pane, already green at 157
```

**Pane layout:** terminal left, dashboard right. Both visible the whole time. Never alt-tab to
something the viewer has not already seen.

Use a **fresh attacker wallet** so reputation starts genuinely at zero.

---

## 0:00 – 0:30 · The problem, with a number

> "Every AMM leaks value to informed flow. When the pool's price drifts from the real price,
> an arbitrageur closes that gap and pockets the difference — that's LVR, and it's the main
> reason passive liquidity underperforms.
>
> Every defensive hook I know of reacts to *price* or to *volatility*. They see the swap. None
> of them see what the swap is **doing**."

**On screen:** the dashboard, quiet, everything at 0.300%.

Do not explain the architecture yet. One problem, one sentence, then move.

---

## 0:30 – 0:55 · The insight

> "Glyph prices a swap by what it does to the pool. Move the pool *toward* the true price and
> you're taking the arbitrage — you pay for it. Move it *away* and you're the uninformed flow
> LPs actually want — you pay the base rate, however big you are, whoever you are.
>
> At UHI9 a judge told us our reputation system was defeated by rotating wallets. He was right.
> So we stopped selling absolution and started selling a discount."

That last line is the pitch. Land it, then prove it immediately.

---

## 0:55 – 1:35 · L1 live — the pair that is the whole argument

**Terminal:** move the reference price 1% below the pool.

```bash
cast send $ORACLE_ADDRESS "setPrice(bytes32,uint256,bool)" $POOL_ID 990000000000000000 true …
```

**Swap in the gap-closing direction.** Dashboard row appears: `arb 5460`, final **0.846%**.

> "This swap closed the gap. It paid 0.85%."

**Swap the other way, same size, same wallet.** New row: `arb 0`, final **0.300%**.

> "Same pool. Same divergence. Same wallet. Opposite direction — base rate.
>
> And the premium isn't a fudge factor. The gap was 101 basis points, we ignore the first ten as
> oracle noise, and we take 60% of the remaining 91. That's 5,460. That's the number on chain."

**This is the single most important 40 seconds.** If you cut anything, cut later.

> "Notice this needed no reputation at all. A brand-new wallet pays it on its first trade —
> which is exactly why rotating wallets doesn't help you."

---

## 1:35 – 2:05 · L2 live — the sandwich pays its victim

```bash
forge script script/SandwichDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Dashboard: **Sandwiches caught** ticks to 1, **Returned to victims** shows the amount.

> "Attacker opens, someone trades into the worse price, attacker reverses out. Same block —
> that's a sandwich.
>
> Most MEV hooks would charge the attacker more and send it to the LPs. But the LP isn't who
> got hurt here. The trader in the middle did. So the surcharge is escrowed **to them**."

**Switch to the victim's wallet and press Claim.** Balance goes up on screen.

> "That's the attacker's money, in the victim's wallet."

---

## 2:05 – 2:35 · One code path, in your own words

Open `GlyphHook.sol` at `_divergence`.

> "Here's the part that matters. v1 computed price impact from `sqrtPriceLimitX96` — but that's
> a slippage bound the *swapper* passes in, and every router sets it to the extreme tick. So
> with feeds on, every swap looked maximally toxic. That's why the feature shipped switched off.
>
> Now it reads `slot0` — the pool's actual price — against the oracle. Neither input is
> controlled by the person paying the fee.
>
> And this line is the direction test: if the pool is above the reference and you're selling into
> it, you're closing the gap. That one comparison is the whole mechanism."

Scroll to `getHookPermissions`, one beat:

> "Permissions are validated against the hook's own address at construction, so a mismatch fails
> the deploy instead of silently never firing."

**Do not read the code aloud.** Explain what it does and why, the way you would to a colleague.

---

## 2:35 – 2:55 · Limits, named before anyone asks

> "Three things I'd want you to know.
>
> Identity is still a heuristic — that's *why* reputation is only a discount now, never the
> defence. Sandwich detection has one false positive we've named and tested: reversing your own
> position around unrelated flow looks identical on-chain. And the demo pool uses a settable
> reference because mock tokens have no Pyth feed — the real adapter is deployed and verified
> beside it.
>
> Everything you just saw is live on Unichain Sepolia. Six contracts, verified, transaction
> hashes in the repo. 157 tests. Thanks for watching."

---

## If the live run breaks mid-take

Do not restart the recording. Say what happened, switch to `forge test`, and show the same
behaviour asserted:

- `test_gapWideningSwap_paysNothingExtra` — the directional claim
- `test_sandwich_victimCanClaim` — the rebate
- `test_freshWallet_paysArbPremiumOnFirstTrade` — the sybil answer

A calm recovery reads as competence. A restart eats a take.

---

## Beat sheet

| Time | Beat | On screen |
|---|---|---|
| 0:00 | LVR, in one sentence | quiet dashboard |
| 0:30 | Price the swap, not the swapper | still dashboard |
| 0:55 | Gap-closing swap → 0.846% | terminal + new row |
| 1:15 | Gap-widening swap → 0.300% | second row beside it |
| 1:35 | Sandwich staged | stats tick up |
| 1:50 | Victim claims, balance rises | wallet |
| 2:05 | `_divergence`, in your words | editor |
| 2:35 | Three disclosed limits | dashboard |
| 2:50 | Live, verified, 157 tests | deployment doc |
