# Demo script — three minutes, one or two sentences per beat

Read this as a teleprompter, not a document. **Every beat is one or two short sentences**, sized
so you can say them while a command runs. Speaking rate is about 2.5 words a second; each block
is budgeted against its slot and the word count is printed so you can check yourself.

Last year this category scored **0** — *"the presentation video is just the website."* Everything
else scored 4 or better. This is the whole delta.

**Panes:** A = `~/glyphh/contract` · B = `~/glyphh/ai/backtest` · browser = dashboard.
**Before every take:** `./script/demo-reset.sh`

---

## 0:00 – 0:24 · The problem
*browser · no command · 50 words · 20s of speech in a 24s slot*

> "Anyone can trade against your liquidity — but some traders only show up when your price is
> wrong, and your pool charges them exactly what it charges everyone else.
>
> Every fix I've seen guesses at it: watch volatility, watch trade size, or watch the wallet —
> and a fresh wallet costs a few cents."

---

## 0:24 – 0:44 · The idea, and the prior art
*browser · no command · 45 words*

> "So Glyph asks what the swap *does* to the pool. Move the price toward where it should be and
> you pay; move it away and you don't.
>
> Charging arbitrage against an oracle isn't my idea — DetoxHook does it. What nobody does is the
> next two layers."

**Do not cut the second sentence.** Naming your closest prior art before a judge can is what
turns a resemblance into evidence you know the field.

---

## 0:44 – 1:02 · L1, first direction
```bash
./script/demo-swap.sh closing        →  arb 3660  ·  0.666%
```
*25 words · command takes 3s*

> "There's a one percent gap between this pool and the real price. That swap just closed it — so
> it paid 0.666% instead of 0.30%."

---

## 1:02 – 1:20 · L1, the other direction
```bash
./script/demo-swap.sh widening       →  arb 0  ·  0.300%
```
*35 words · command takes 6s*

> "Same pool, same gap, same size, same wallet — opposite direction, base rate.
>
> And that number isn't a setting: 101 basis points, ignore the first 40, sixty percent of what's
> left is 3,660."

---

## 1:20 – 1:40 · L2, the sandwich
```bash
./script/demo-sandwich.sh            →  credited 4.870087  ·  toxicity 4999
```
*38 words · command takes 9s*

> "That's a sandwich — someone jumps in front of your trade and closes out behind you.
>
> Every other hook charges that attacker more and hands the money to the liquidity providers. But
> the LP isn't who got hurt."

---

## 1:40 – 1:56 · L2, the victim is paid
```bash
./script/demo-claim.sh               →  1141.45 → 1146.32
```
*35 words · command takes 13s, the slowest — you need every word*

> "That's the attacker's money, in the victim's wallet, out of the same transaction that took it.
>
> No registration, no proof to submit — the hook escrowed it to their address in the block it
> happened."

---

## 1:56 – 2:18 · L3, and last year's objection
*browser · no command · 50 words*

> "The third layer is reputation, and it only ever makes the fee cheaper — trade honestly long
> enough and you get 0.05%.
>
> Last year a judge told me rotating wallets beat my score. He was right — so now a fresh wallet
> isn't back to free, it's back to unproven."

---

## 2:18 – 2:40 · The number, and the bug I found in myself
```bash
python3 lvr.py                       →  82.4% vs 54.4%
```
*50 words · command takes 2s*

> "Thirty days of real ETH data: the pool keeps 82% of the arbitrage instead of 54%.
>
> The first run also said I was overcharging 44% of ordinary swaps — that was my bug, I'd set the
> threshold below the fee where no arbitrageur even trades. I fixed it and redeployed."

**This is worth more than another feature.** It shows you understood your own mechanism well
enough to catch it being wrong.

---

## 2:40 – 2:58 · Limits, then close
```bash
forge test                           →  181 passed
```
*44 words · command is instant*

> "Three limits: identity is still a heuristic, sandwich detection has one false positive I've
> named and tested, and the demo pool prices against a settable reference because mock tokens
> have no feed.
>
> It's all live on Unichain Sepolia. 181 tests, every hash in the repo."

---

## If a command fails mid-take

Don't restart. Say what happened, switch to pane B, show the test that asserts the same thing:

```bash
forge test --match-test test_gapWideningSwap_paysNothingExtra    # the directional claim
forge test --match-test test_sandwich_victimCanClaim             # the rebate
forge test --match-test test_arb_toleranceClearsTheNoArbitrageBand
```

A dim `rpc hiccup, retrying` line is **normal** — the wrappers retry automatically. Don't react
to it.

---

## The whole thing on one card

| Time | Pane | Command | Say |
|---|---|---|---|
| 0:00 | — | — | Anyone can trade against your liquidity… every fix guesses |
| 0:24 | — | — | What the swap *does*, not who sent it · **name DetoxHook** |
| 0:44 | A | `demo-swap.sh closing` | One percent gap — that swap closed it, paid 0.666% |
| 1:02 | A | `demo-swap.sh widening` | Same everything, opposite direction — base rate · the arithmetic |
| 1:20 | A | `demo-sandwich.sh` | That's a sandwich · everyone else pays the LPs |
| 1:40 | A | `demo-claim.sh` | Attacker's money, victim's wallet |
| 1:56 | — | — | Reputation only makes it cheaper · last year's objection |
| 2:18 | B | `python3 lvr.py` | 82% vs 54% · **the bug I found in myself** |
| 2:40 | A | `forge test` | Three limits · live, verified, 181 tests |

Total spoken: **~370 words ≈ 2:28** across a 2:58 runtime — every beat has slack, and the
slowest command (the claim, 13s) is the one with the most words to cover it.
