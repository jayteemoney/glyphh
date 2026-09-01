# 03 — The ecosystem gap: where Glyph is new, and where it is not

Most project docs claim total novelty. That claim does not survive a judge who knows the
field, and the fastest way to lose a technical audience is to have them name your prior art
before you do. So this doc names it first.

---

## The landscape, by what the defence reacts to

| Approach | Example | Signal | Value goes to | Sandwich victim made whole? |
|---|---|---|---|---|
| Static fee tiers | Uniswap v3 | none | LPs | ✗ |
| Volatility-reactive fees | AdaptiveSwap (UHI4) | realized volatility | LPs | ✗ |
| Directional fees, oracle-free | Nezlobin's design | recent pool price drift | LPs | ✗ |
| Oracle-divergence capture | **DetoxHook** | pool vs Pyth gap | **LPs (80%), protocol (20%)** | ✗ |
| Retrospective victim rebate | **MEVictim Rebate** | off-chain subgraph + Axiom proof | victims, as an **LP incentive** | partially, later |
| Private order flow | MEV-protect RPCs, CoW | the victim's tx | — | avoided, not compensated |
| Auction the right to extract | am-AMM, MEV taxes | bidding | LPs / pool | ✗ |
| **Glyph** | | **divergence + direction, block-local sandwich shape, earned history** | **LPs, and the victim directly** | **✓ same block, attacker-funded** |

---

## Where Glyph is *not* new — L1

**Oracle-divergence arbitrage capture is an established pattern, and Glyph's L1 is a
refinement of it, not an invention.**

[DetoxHook](https://github.com/hamiha70/detox-hook) prices swaps against Pyth, captures a
fixed percentage of the detected arbitrage through v4's dynamic fee, and donates the result to
LPs. Its capture rate is 70%; Glyph's is 60%. Anyone claiming that Glyph invented charging
arbitrageurs a proportion of the gap they close is wrong, and a judge who has seen DetoxHook
will know it.

[Nezlobin's directional fee](https://x.com/AlexNezlobin) — which Atrium teaches in this very
cohort — reaches a similar place without an oracle at all, tilting the fee against the
direction implied by the pool's own recent price drift.

Two honest technical distinctions remain in L1, and they are refinements:

| | DetoxHook | Glyph L1 |
|---|---|---|
| Trigger threshold | ~2% arbitrage opportunity | **10 bps** of divergence |
| Price compared | the swap's execution price | the pool's **pre-swap `slot0`** |
| Capture | 70% | 60% |

The threshold difference is the substantive one. Most LVR is bled through gaps far under 2%;
a 2% floor leaves the ordinary case uncharged. And comparing pre-swap `slot0` rather than
execution price means the measurement is independent of the swap's own size — a large swap
cannot inflate the divergence it is then charged for.

Against Nezlobin, the distinction is that a backward-looking drift signal is stale by
construction and prices a *direction*, while Glyph prices the **live gap this specific swap
closes** — so a 5 bp gap and a 500 bp gap get different prices rather than the same tilt.

**And a real cost, disclosed:** Nezlobin's design needs no oracle. Glyph's L1 does. Where no
reference price is available the layer degrades silently to the base fee, and the pool falls
back to L2 and L3 alone. That is a genuine advantage Nezlobin's approach holds over ours.

---

## Where Glyph *is* new — L2

**No deployed design routes a sandwich surcharge to the sandwiched trader, in the same
transaction, funded by the attacker.**

The nearest prior art is [MEVictim Rebate](https://ethglobal.com/showcase/mevictim-rebate-qsxak),
which identifies victims *retrospectively* with a subgraph and an Axiom circuit, then mints
them an ERC-721 that qualifies for a rebate when they later provide liquidity. Three
differences, and each one matters:

1. **When.** MEVictim identifies victims after the fact, off-chain. Glyph detects the sandwich
   shape inside `afterSwap`, in the block it happens.
2. **Who pays.** MEVictim's rebate is an LP incentive — the protocol funds it. Glyph's rebate
   is taken from the attacker's closing leg through `afterSwapReturnDelta` and
   `poolManager.take`. **The attacker funds the victim.**
3. **What the victim must do.** MEVictim requires becoming an LP to collect. Glyph escrows to
   the victim's address; they call `claim` and are paid.

This is the point where the field consistently stops, and it is worth being explicit about
why it matters. **Every other MEV hook that charges a sandwicher more routes the money to
liquidity providers** — DetoxHook donates 80% to LPs, and that is the norm. But the LP is not
who a sandwich harms. The trader in the middle is. Paying LPs leaves the injured party exactly
as badly off as before and merely relocates the extraction.

---

## Where Glyph *is* new — L3

**Reputation inverted into a discount is, as far as we can find, unprecedented in a v4 hook.**

Every reputation-flavoured design — including Glyph v1 — makes the clean state the default and
the default free. That is what makes wallet rotation a complete reset, and it is the flaw the
UHI9 judge identified in one sentence.

Glyph v2 inverts it. Unknown identities pay a size-scaled premium; proven-benign history earns
the fee *down*, below base, to a 0.05% floor. Rotating a wallet no longer returns an attacker
to free. **It returns them to unproven**, and forfeits trust that took ten settled swaps and
thirty days of non-decay to accumulate.

The sybil objection cannot reach a mechanism where the fresh-wallet state is the expensive one.

---

## Where Glyph is new as a *system*

The three layers are ordered by how much identity they need, and the first two need none:

```
L1  divergence + direction    identity-free    fires on trade #1 of a brand-new wallet
L2  same-block sandwich       identity-free    within a block, addresses need not be known
L3  reputation                identity-based   discount only; never the defence
```

Even if the identity layer is sybilled completely, L1 and L2 still fire at full strength. No
other design in the table degrades gracefully in that direction, because no other design has
more than one layer.

---

## Durable advantages

1. **The cost falls only on extraction.** Volatility-reactive fees raise the price for
   everyone precisely when honest traders most need to trade. Glyph's honest-flow price is
   0.30% in every market condition, and 0.05% once earned. No constituency pushes back on
   adoption.
2. **It composes rather than competes.** A pool can run volatility-reactive *and* Glyph;
   private order flow keeps protecting swappers while Glyph protects LPs and pays victims.
   There is no incumbent to displace.
3. **The registry is a primitive, not a feature.** `ReputationRegistry` is a standalone
   contract any protocol can read — lending markets pricing borrowers, perps venues tiering
   takers, RFQ systems filtering flow. The hook is its first consumer, not its only one.
4. **Cross-pool coverage is O(1).** One Reactive subscription covers every Glyph pool that
   will ever deploy, and propagation is gated on *distinct* pools so a repeat offender in one
   venue does not spam the network.
5. **Every claim is checkable.** The fee decomposition is in the event log, the contracts are
   `exact_match` on Sourcify, and the two transactions that carry the central argument are
   public.

---

## What we would concede in a Q&A

- **L1 is a better-tuned version of an idea that already exists.** We think the tuning matters
  and can show why, but we did not invent oracle-divergence capture.
- **L1 needs an oracle.** Nezlobin's approach does not.
- **The demo pool prices against a settable reference, not Pyth**, because mock tokens have no
  feed. `PythPriceOracle` is deployed and verified beside it; the hook cannot tell them apart.
- **Sandwich detection has a bounded, named false positive** — a trader reversing their own
  position around unrelated flow. Tested as
  `test_knownFalsePositive_selfReversalAroundUnrelatedFlow`.

See [04 — Users and positioning](04-USERS-AND-POSITIONING.md) for who this is for.
