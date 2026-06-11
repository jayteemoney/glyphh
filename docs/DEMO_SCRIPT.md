# Glyph — 3-Minute Demo Video Script

Everything below runs against the **live Unichain Sepolia deployment** (`docs/DEPLOYMENT.md`)
and has been verified end-to-end. Total on-screen time: ~3:00.

## Screen layout

Three terminals + one browser window:

| Pane | Runs |
|---|---|
| Terminal A (left) | `keeper` — the autonomous detector |
| Terminal B (right-top) | `clean_trader.ts` then `attacker_bot.ts` |
| Browser | https://glyphh-alpha.vercel.app/dashboard (or `localhost:3000` if offline) — live scores + toxic feed |

## Prep (before recording — not in the video)

```bash
# 1. dashboard
cd frontend && pnpm dev          # → localhost:3000/dashboard

# 2. keeper (Terminal A) — leave running
cd ai && source .venv/bin/activate
python -m detector.keeper

# 3. fresh attacker wallet so the video shows 0 → 8000 in one burst
cast wallet new                                  # → new key + address
# fund it (from contract/, with .env loaded):
cast send <NEW_ADDR> --value 0.002ether --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN_A "mint(address,uint256)" <NEW_ADDR> 100000000000000000000 --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
cast send $TOKEN_B "mint(address,uint256)" <NEW_ADDR> 100000000000000000000 --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC_URL
# paste the new key into demo/.env → ATTACKER_PRIVATE_KEY
```

> The clean trader wallet can be reused — its score is 0 and stays 0.

## The script

**0:00 – 0:25 — the pitch (dashboard on screen)**
> "AMM LPs bleed value to MEV bots — every defensive hook today reacts to *price*, never the
> *trader*. Glyph is a Uniswap v4 hook that prices each swap by who is trading: a live,
> decaying reputation score per wallet. This is our dashboard watching the live testnet
> deployment; both wallets start clean."

**0:25 – 0:55 — honest flow keeps the base fee (Terminal B)**
```bash
cd demo && npx tsx clean_trader.ts
```
> "A normal trader: paced, alternating swaps. The keeper on the left sees every swap and
> scores it — zero. Every swap pays the 0.30% base fee. Honest flow is never punished."

Point at Terminal A: keeper lines reading `model score → 0/10000`.

**0:55 – 1:50 — the attack, caught autonomously (Terminal B)**
```bash
npx tsx attacker_bot.ts
```
> "Now an MEV-style burst: large, same-direction swaps, seconds apart. Watch the keeper —
> no human touches anything. Mid-burst it recognises the directional burst, signs an EIP-712
> attestation, and pushes the score on-chain: **0 → 8000**. The very next swap from this
> wallet pays a **5.2% fee instead of 0.30%** — about 17x — and the entire premium is
> credited to LPs in the same transaction."

Point at: Terminal A `🚨 FLAGGED … score 0 → 8000`, Terminal B fee jumping, dashboard score
bar + toxic-trades feed updating.

**1:50 – 2:25 — LP-positive + cross-pool (dashboard / explorer)**
> "The dashboard tallies the LP donations live — toxic flow has become LP yield. And because
> a Reactive Smart Contract on the Reactive Network subscribes to the registry, a wallet
> flagged in one pool is repriced in *every* Glyph pool within seconds. One sensor, every
> pool protected."

Optionally show a flagged-swap tx on https://sepolia.uniscan.xyz with the `LPDonation` event.

**2:25 – 3:00 — fairness + close**
> "Scores aren't a blacklist — they decay linearly to zero over seven days; stop attacking
> and you recover. On-chain: registry, hook and Reactive engine live on Unichain Sepolia and
> Reactive Lasna. Off-chain: an ML detector that signs attestations the contract verifies.
> Glyph: the first hook that prices *who* is trading, not just what."

## Verified numbers to quote

| Claim | Evidence |
|---|---|
| Clean swap fee 0.30% | keeper log `fee=0.30%`, bot output |
| Flag mid-burst, no human | keeper `🚨 FLAGGED … 0 → 8000 (nonce …, tx …)` |
| Toxic fee 5.20% (~17x) | bot output `fee 5.200%` after flag |
| Premium → LPs | `LPDonation` events on the hook each toxic swap |
| Decay live | on-chain score reads 7999, 5443… (linear 7-day decay) |
