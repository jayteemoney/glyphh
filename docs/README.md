# Glyph documentation

**A Uniswap v4 hook that prices a swap by what it does to the pool — not by who sent it.**

This folder is the written case for the project. The repository [`README`](../README.md) is
the two-minute version; these are the arguments behind it.

## Read in this order

| Doc | What it answers |
|---|---|
| [01 — The problem](01-PROBLEM.md) | What bleeds LPs, and why every existing defence misses it |
| [02 — The solution](02-SOLUTION.md) | The three layers, the fee arithmetic, and the live numbers |
| [03 — The ecosystem gap](03-ECOSYSTEM-GAP.md) | Named prior art, what Glyph did not invent, and what it did |
| [04 — Users and positioning](04-USERS-AND-POSITIONING.md) | Who this is for and why it compounds |

## Reference

| Doc | Contents |
|---|---|
| [DEPLOYMENT.md](DEPLOYMENT.md) | Live addresses (single source of truth) + the transactions that prove each claim |
| [USER-GUIDE.md](USER-GUIDE.md) | Cold clone to claimed rebate, local and on testnet |
| [DEPLOY-RUNBOOK.md](DEPLOY-RUNBOOK.md) | Reproducing the deployment |
| [BACKTEST.md](BACKTEST.md) | What the fee model does to real historical flow |
| [UHI10-CHANGELOG.md](UHI10-CHANGELOG.md) | Every v2 change mapped to the judging criterion it serves |

## The thesis in three sentences

Passive AMM liquidity is adversely selected: the swaps that trade against it most profitably
are the ones that know something it doesn't, and every existing defence prices a *proxy* for
that — volatility, order size, price drift — or prices the *sender*, which anyone can change
for the cost of a fresh wallet. Glyph prices the thing itself: a swap that moves the pool
toward the true price is capturing the divergence and pays 60% of what it closes, while a swap
that moves the pool away pays the base rate at any size from any wallet. On top of that, a
sandwich's closing leg is surcharged and the money is escrowed **to the trader it squeezed**,
and flow that has proven itself over time earns the fee *down* to 0.05% — so rotating a wallet
no longer returns an attacker to free, it returns them to unproven.
