# UHI10 changelog

Glyph v1 competed in UHI9. This file records what changed for UHI10, why, and which judging
criterion each change serves — so a judge can see what is new without reading a git log.

**Baseline:** commit `31c6cbb` (11 June 2026, end of UHI9).
**Window:** 17 August – 3 September 2026.
The diff against the baseline is the submission.

---

## The one-line summary

v1 priced swaps on reputation alone. v2 prices them on **what the swap does to the pool**, with
reputation demoted to a discount. That single inversion is what closes the sybil hole the UHI9
judge identified, and everything below follows from it.

---

## Original Idea

| Change | Why it matters |
|---|---|
| **Reputation became a discount, not the fee.** Unknown identities pay a size-scaled premium; proven-benign history earns the fee *down* to a 0.05% floor. | v1's clean state was the default, so it was free, so rotating to a fresh EOA reset the game. Rotation now forfeits something rather than escaping something. |
| **L1: directional arbitrage premium.** Divergence *and direction*: closing the oracle gap is arbitrage and pays; widening it is uninformed flow and never pays. | Identity-free. A brand-new wallet pays on trade #1, so the sybil objection cannot reach it. It is also the sharpest available statement of what LPs actually lose to. |
| **L2: sandwich surcharge routed to the victim**, not to LPs. | The party a sandwich harms is the trader in the middle. Every "charge the attacker more" hook pays LPs and leaves the victim exactly as badly off. |
| **Trust is depth × quality**, gated on a minimum history. | Makes "proven" expensive to reach, which is what gives the inversion teeth. |

## Unique Execution

| Change | Why it matters |
|---|---|
| **`BaseGlyphHook`** — an `IHooks` base with reverting defaults and constructor-time `Hooks.validateHookPermissions`. | The rubric names `BaseHook`/`getHookPermissions`. v4 derives permissions from the hook's *address* while `getHookPermissions` is just a function; nothing forces agreement. A mismatch is now a failed deployment, not a callback that silently never fires. Deletes ~70 lines of v1 stubs. |
| **`afterSwapReturnDelta` + `poolManager.take`** for the rebate path. | Real flash accounting. `take` leaves the hook owing; the returned delta credits it; they net to zero and the swapper is debited. |
| **EIP-1153 transient storage** (`SwapGuard`), with a per-leg sequence number. | v1 kept swap state in a persistent mapping keyed `(poolId, tx.origin)`, so a multi-hop route through one pool had the second leg read the first leg's fee. Proven fixed by `test_multiHop_legsDoNotCollide`. |
| **`IPriceOracle` adapter seam.** | The hook depends on an interface, not on Pyth. A second source can be added without touching `GlyphHook` — and it is why the divergence path is testable at all. |
| **Tests: 69 → 157**, plus 19 Python. Mock oracle, fuzz over the whole fee model, invariant bounds, negative sandwich cases. | v1's toxicity branch had *zero* coverage: every test constructed the hook with `IPyth(address(0))`. |

## Functionality

| Change | Why it matters |
|---|---|
| **Fixed the bug that made v1's toxicity check unusable.** `_estimatePriceImpactBps` derived the swap's price from `params.sqrtPriceLimitX96` — a slippage bound the *swapper* supplies, which every router sets to the extreme tick. With feeds configured, divergence saturated on every swap and honest retail read as maximally toxic. | This is why the Pyth auto-flag shipped **disabled** in v1. Divergence now comes from `slot0`; neither input is swapper-controlled. The feature is finally on in production. |
| **Severity carries the measured divergence**, not the constant threshold. | v1 scored a 10,000 bp attack and a 201 bp one identically. |
| **`reportToxicSwap` keyed on the real `PoolId`.** | v1 passed the hook's own address, so every pool behind one hook reported as one pool and cross-pool aggregation could not distinguish them. |
| **Sandwiches that don't start the block are now detected.** Sliding two-swap window replaces single-opener tracking. | Real blocks carry unrelated flow ahead of an attack, so the original design would have missed essentially every real sandwich. Test written failing first. |
| **Deployed and verified**: six contracts on Unichain Sepolia, all `exact_match` on Sourcify; `GlyphReactive` live on Lasna and funded. | The configured explorer key was a 5-character placeholder that returns HTML — Etherscan verification was never going to work. Sourcify needs no key and proves bytecode came from exactly this source. |
| **Fixed a frontend backfill that silently rendered an empty dashboard.** The RPC caps `eth_getLogs` between 10k and 50k blocks and returns HTTP 400 rather than truncating; the `catch` turned that into "no activity yet". | Would have shown a blank dashboard during the demo. Chunked reader verified live: 11 `FeeQuoted`, 1 `SandwichDetected`, 1 `ToxicSwapReported`. |
| **Lint clean**, mount guards rebuilt on `useSyncExternalStore`. | CI green. |

## Impact

| Change | Why it matters |
|---|---|
| **Every claim is reproducible on a public chain**, with transaction hashes in `docs/DEPLOYMENT.md`. | The directional pair (0.846% vs 0.300%), the sandwich rebate paid and claimed, the callback authorization boundary — all verifiable without running anything. |
| **Cross-pool propagation became real**, gated on distinct pools. | v1's second headline claim could not have survived a judge checking it. |
| **`FeeQuoted` emits every term separately.** | Turns "the model is fair" into something a trader can audit line by line, and gives the detector an *exact* record of which swaps were uninformed — for one log scan instead of replaying oracle history. |

## Presentation

| Change | Why it matters |
|---|---|
| **Dashboard shows why a swap was priced**, not just what it cost — stacked bar per swap, with a plain-language reason. | UHI9's presentation score was the single largest gap. |
| **Rebate claim in the UI.** | A judge can connect a wallet and be paid. |
| **Disclosed limitations in the README**, each with its production path, rather than left for a judge to find. | Technical judges reward disclosed constraints and punish discovered ones. |

---

## Mistakes we made and fixed

Recorded because the corrections are more informative than the code.

- **The trust model was wrong on first write.** A flat weighted sum gave a wallet with *no
  history* 500 trust — "never sandwiched" is true of a wallet that never traded — and gave a
  95%-gap-closing arbitrageur 5818, because volume and age carried it. Both reopen the hole the
  inversion exists to close. Rebuilt as depth × quality; sanity-checked across six scenarios.
- **`DemoSetup` wrapped pool `initialize` in try/catch.** Idempotent in simulation, but forge
  still records the call for broadcast, where it reverted and failed the run *after* every other
  step succeeded.
- **A placeholder `ETHERSCAN_API_KEY` was worse than none.** Its presence made forge default to
  the Etherscan verifier and flood every trace with deserialisation errors, masking the real
  failure above for three attempts.
- **v1's tests used `vm.prank(addr)`**, which sets `msg.sender` but not `tx.origin` — so the hook
  read Foundry's default sender and `test_swapSucceeds_toxicTrader` never once exercised a
  non-base fee. v1's headline behaviour was passing a test that did not test it.
