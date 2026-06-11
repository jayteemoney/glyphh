# Glyph documentation

**Glyph is the first Uniswap v4 hook that prices each swap by *who* is trading, not just what.**
This folder is the complete written case for the project — for judges, reviewers, and anyone
evaluating it.

## Read in this order

| Doc | What it answers |
|---|---|
| [01 — The problem](01-PROBLEM.md) | What is bleeding LPs dry, and why nothing on the market stops it |
| [02 — The solution](02-SOLUTION.md) | How Glyph works, end to end, with live verified numbers |
| [03 — The ecosystem gap](03-ECOSYSTEM-GAP.md) | The landscape of LP defenses and the axis they all miss |
| [04 — Who it's for & positioning](04-USERS-AND-POSITIONING.md) | The users, the wedge, and why this compounds into a moat |
| [05 — UHI submission fit](05-UHI-SUBMISSION.md) | Theme and judging alignment, plus the Reactive and Unichain integrations in depth |
| [06 — User guide](06-USER-GUIDE.md) | How to actually use it: visitors, traders, LPs, pool deployers, operators, integrators |

## Reference docs

| Doc | Contents |
|---|---|
| [CONTRACT_GUIDE.md](CONTRACT_GUIDE.md) | Contract-level architecture and interfaces |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Live testnet addresses (single source of truth) + verification txs |
| [DEMO_SCRIPT.md](DEMO_SCRIPT.md) | The 3-minute demo video runbook, timed and verified |

## The thesis in three sentences

Passive AMM liquidity is adversely selected: arbitrageurs, sandwichers and MEV bots extract
value from LPs on every block, and every existing defense reacts to *symptoms* — price,
volatility, order size — never to the *agent* causing them. Glyph gives every wallet an
on-chain reputation score and makes the swap fee a function of it: honest flow pays 0.30%,
toxic flow pays up to 10%, and the entire premium is credited to LPs in the same transaction.
A wallet flagged in one pool is repriced in every Glyph pool within seconds — and because
scores decay to zero over seven days, it's a price, not a blacklist.
