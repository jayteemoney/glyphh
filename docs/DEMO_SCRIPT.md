# Demo script — three minutes, every layer exercised

Recorded in your own voice, screen captured. The rubric explicitly marks down AI-produced
presentations and rewards *demonstrating genuine understanding of the code*, so the rule
throughout is **run it, then say what it means in your own words**. Never narrate a static page.

Last year's score for this category was **0** — *"the presentation video is just the website."*
Everything else scored 4 or better. This is the whole delta.

**Total: 2:55.** Every one of the three layers fires on camera, plus the backtest and the test
suite. Rehearse until you can hit the beats without reading; record at least three takes.

---

## Before you record

```bash
# 1. Local stack, so nothing depends on a public RPC mid-take
anvil &
cd contract && DEPLOYER_PRIVATE_KEY=0xac09…ff80 \
  forge script script/LocalDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# 2. Paste the printed addresses into demo/.env and frontend/.env.local
# 3. Frontend up at localhost:3000/dashboard, wallet connected
# 4. Panes pre-warmed, each with its command typed but NOT run:
#      pane A  forge test                       (181 passing)
#      pane B  cd ai/backtest && python3 lvr.py (backtest, ~40s — start it early)
#      pane C  the swap commands below
```

**Pane layout:** terminal left, dashboard right, both visible throughout. Never alt-tab to
something the viewer has not already seen.

Use a **fresh attacker wallet** so reputation genuinely starts at zero.

**Start the backtest in pane B during the 0:00 beat** so its output is on screen by 2:15
instead of making the viewer wait.

---

## 0:00 – 0:25 · The problem

**On screen:** the dashboard, quiet, everything at 0.300%.

> "If you provide liquidity to a pool, you're making one offer to everybody. And that's the
> problem, because not everybody is the same.
>
> Most people swapping are just… swapping. But some traders only show up when your price is
> wrong. They're not taking a risk — they're collecting. And your pool charges them exactly what
> it charges everyone else.
>
> Every fix I've seen guesses at this. It watches volatility, or trade size, or which way the
> price drifted. Those are hints, not the thing itself. The other approach is to watch the
> *wallet* — and that stops working the moment someone funds a new one."

One problem, plainly. Don't touch the architecture yet.

---

## 0:25 – 0:45 · The idea, and being straight about what's ours

> "So Glyph asks a different question. Not who sent this swap — **what does this swap do to the
> pool?**
>
> Push the price toward where it should be, and you're collecting the gap. You pay for that.
> Push it away, and you're the ordinary flow that liquidity providers actually want. You pay the
> normal rate. Any size. Any wallet.
>
> I want to be straight with you about one thing. Charging arbitrage against an oracle isn't my
> idea — DetoxHook does it, and Nezlobin's directional fee gets there without an oracle at all.
> What nobody does is the two layers after it: paying the sandwich victim out of the attacker's
> own money, and turning reputation into a discount so that switching wallets costs you something
> instead of saving you something."

**This beat decides your originality score.** Anyone who knows the field will think "DetoxHook"
whether you say it or not. Say it first and it becomes evidence you know the landscape — and it
sets up L2 and L3 as the real claims.

---

## 0:45 – 1:20 · L1 live — the pair that is the whole argument

**Pane A:**

```bash
./script/demo-swap.sh closing
```

Prints `arb 3660`, final **0.666%**.

> "There's a one percent gap between this pool and the real price. That swap closed it — so it
> paid 0.666%."

```bash
./script/demo-swap.sh widening
```

Prints `arb 0`, final **0.300%**.

> "Same pool. Same gap. Same size. Same wallet. I just went the other way — and it's the normal
> rate.
>
> And that number isn't a setting I picked. The gap was 101 basis points. We ignore the first 40,
> because under that nobody's arbitraging anyway — the fee already eats it. Sixty percent of
> what's left is 3,660. That's the number in the event log, and you can go and read it yourself."

> "Notice there was no reputation in that at all. A wallet made ten seconds ago pays this on its
> first trade. That's the whole answer to 'just use a new wallet'."

**If you cut anything, cut later.** This is the most important 35 seconds.

---

## 1:20 – 1:50 · L2 live — the sandwich pays its victim

```bash
./script/demo-sandwich.sh
```

> "This is a sandwich. Someone jumps in front of your trade, you get a worse price, they close
> out behind you and keep the difference.
>
> Now — every other hook I've seen charges that attacker more and hands the money to the
> liquidity providers. DetoxHook sends eighty percent to LPs. But the LP isn't who got hurt here.
> **You** did. Paying the LPs just moves the money somewhere else."

```bash
./script/demo-claim.sh
```

Balance goes `1136.589355` → `1141.456600`.

> "That's the attacker's money, in the victim's wallet, out of the same transaction that took it."

---

## 1:50 – 2:15 · L3, and the answer to last year's objection

> "The third layer is reputation, and it only ever makes the fee *cheaper*. Trade honestly for
> long enough and you get 0.05% — six times cheaper than the pool's normal rate.
>
> Last year a judge told me my reputation system fell over the moment someone rotated wallets. He
> was completely right. The reason it broke is that being unknown was **free** — so becoming
> unknown again was a full reset.
>
> So I flipped it. Now a new wallet isn't back to free, it's back to **unproven** — and it's given
> up a discount that took real trading to earn."

---

## 2:15 – 2:40 · The number, and the bug I found in my own model

**Pane B:**

```bash
python3 lvr.py
```

> "I ran thirty days of real ETH price data through this. The pool keeps 82% of the arbitrage
> instead of 54% — about $143,000 back to liquidity providers in a month, on a ten million dollar
> pool.
>
> But the first time I ran it, it told me 44% of ordinary swaps were being overcharged. That was
> my bug. I'd set the threshold at 10 basis points thinking 'that's just oracle noise.' Wrong
> frame — below 30 basis points, which is the fee, no arbitrageur bothers trading. So everything I
> was charging down there was ordinary people.
>
> I moved it to 40. That dropped from 44% to one and a half. Then I redeployed — which is why the
> fee you saw was 0.666% and not 0.846%."

**This beat is worth more than it looks.** It shows you understand your own mechanism well enough
to catch it being wrong, and that the number on screen came from evidence rather than taste.

---

## 2:40 – 2:55 · What I'd want you to know before you ask

**Pane A:** run `forge test` so it lands green while you talk.

> "Three things, before you ask me.
>
> Working out who sent a swap is still a heuristic — and that's exactly *why* reputation only ever
> gives a discount. If I get it wrong, someone loses a discount they earned. Nobody gets through
> who shouldn't.
>
> Sandwich detection has one false positive, and I've named it and written a test for it: if you
> reverse your own position and someone unrelated trades in the middle, that looks identical from
> the outside.
>
> And this demo pool prices against a reference I can set, because these are mock tokens with no
> Pyth feed. The real Pyth adapter is deployed and verified right next to it.
>
> Everything you just watched is live on Unichain Sepolia. Six contracts, all verified, every
> transaction hash is in the repo. 181 tests, 94% coverage. Thanks for watching."

---

## If the live run breaks mid-take

Do not restart the recording. Say what happened, switch to pane A, show the same behaviour
asserted:

- `test_gapWideningSwap_paysNothingExtra` — the directional claim
- `test_sandwich_victimCanClaim` — the rebate
- `test_freshWallet_paysArbPremiumOnFirstTrade` — the sybil answer
- `test_arb_toleranceClearsTheNoArbitrageBand` — the backtest finding

A calm recovery reads as competence. A restart eats a take.

---

## Beat sheet

| Time | Beat | Pane | Command |
|---|---|---|---|
| 0:00 | The problem, plainly | browser | — |
| 0:25 | The idea, and naming the prior art | browser | — |
| 0:45 | Gap-closing swap → **0.666%** | **A** | `./script/demo-swap.sh closing` |
| 1:05 | Gap-widening swap → **0.300%** | **A** | `./script/demo-swap.sh widening` |
| 1:20 | Sandwich staged | **A** | `./script/demo-sandwich.sh` |
| 1:38 | Victim is paid | **A** | `./script/demo-claim.sh` |
| 1:50 | Discount, not penalty — the sybil answer | browser | — |
| 2:15 | 82% vs 54%, and the bug I found | **B** | `python3 lvr.py` |
| 2:40 | Three disclosed limits | browser | — |
| 2:50 | Live, verified, 181 tests | **A** | `forge test` |

Pane A is `~/glyphh/contract`, pane B is `~/glyphh/ai/backtest`. Run `./script/demo-reset.sh`
before every take — it re-solves the reference so the fee is exactly 0.666%, and clears the
vault so the sandwich beat rises from zero.

## What this covers that last year's didn't

| | UHI9 video | This one |
|---|---|---|
| Layers shown running | 0 | **3** |
| Live transactions on camera | none | 4 |
| Own voice explaining the code | no | yes, twice |
| Quantified impact | none | 82% vs 54%, $143k/month |
| Limitations disclosed | no | three, plus one self-found bug |
| Prior art acknowledged | no | three named projects |
