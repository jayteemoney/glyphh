# 06 — User guide

Everything you need to use Glyph, whoever you are. Each section stands alone, so jump to
the one that matches you. Contract addresses referenced throughout live in
[DEPLOYMENT.md](DEPLOYMENT.md).

---

## I just want to see it work

You need a browser wallet (MetaMask or any injected wallet) and two minutes.

1. **Open the app** at [glyphh-alpha.vercel.app](https://glyphh-alpha.vercel.app). The hero
   card shows the core idea: the same pool quoting two very different fees to two very
   different traders.
2. **Click "Connect wallet"** in the top right (or any of the big buttons). Approve the
   connection in your wallet. If you are on another network, the button changes to
   "Switch network" and one click moves you over.
3. **You're in.** The dashboard opens with a card showing *your* wallet's reputation, the
   exact fee any Glyph pool would quote you right now, and your risk tier. For almost
   everyone this reads `0 / 10,000`, `0.30%`, `clean` — which is the point. The pool
   already knows you're fine.
4. **Look around.** The stats row totals what LPs have been paid and how many wallets are
   flagged. The reputation table lists every scored wallet with its live, decaying score.
   The activity feed shows flags as they happen, labelled by whether the detector or a pool
   itself raised them.

Leave the dashboard open while the demo bots run and you will watch a wallet get caught in
real time: score climbing, fee jumping, LP payouts ticking up.

---

## I'm a trader

There is nothing to learn and nothing to configure. Swap through any Glyph pool exactly as
you would any other v4 pool.

- If you trade like a person — any size, any frequency, balanced in direction over time —
  your score stays at zero and you pay the standard 0.30%, always, in any market.
- The fee only climbs for wallets whose recent pattern looks like extraction: rapid bursts
  of large swaps, all in one direction, again and again.
- If you ever did get flagged, nothing is permanent. Scores fall back to zero over seven
  days on their own. No appeal, no governance vote, no support ticket. Trade normally and
  the pool forgets.

You can check your own standing anytime: connect to the dashboard and read your score and
quoted fee at the top of the page.

---

## I'm a liquidity provider

You do nothing differently, and that is the feature.

1. Provide liquidity to a pool that uses the Glyph hook (the pool's hook address tells you;
   the live one is listed in [DEPLOYMENT.md](DEPLOYMENT.md)).
2. Protection is on from your first block. Wallets with toxic history pay up to 10% on
   every swap against your liquidity instead of 0.30%.
3. The premium is yours. Everything charged above the base fee accrues to in-range
   positions through normal fee growth, in the same transaction as the toxic swap. There is
   no claim to file, no token to stake, no extra contract to trust with your funds.
4. Watch it accumulate on the dashboard: the "LP donated" totals are exactly these
   premiums, counted live.

The hook never holds your tokens. It only sets the fee and reports behaviour; custody stays
with the PoolManager like any v4 pool.

---

## I'm launching a pool

Any v4 pool becomes a Glyph pool by pointing at the hook when you initialize it.

1. Build your `PoolKey` with `fee = DYNAMIC_FEE_FLAG` (`0x800000`), your tick spacing, and
   `hooks` set to the Glyph hook address.
2. Initialize through the PoolManager as usual and seed liquidity.
3. That's it. Your pool reads the shared registry from its first swap, which means every
   wallet ever flagged anywhere is already priced correctly in your pool on day one. You
   inherit the network's whole memory instantly.

Worked example: `contract/script/DemoSetup.s.sol` initializes a dynamic-fee pool against
the hook, adds wide-range liquidity, and wires a test swap router. Use it as a template.

---

## I'm running the detector (operator)

The detector keeper is what makes scoring autonomous. One terminal, one process.

```bash
cd ai
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # fill: RPC, registry/hook/pool-manager addresses,
                            # pool currencies, and your attestor private key
python -m detector.keeper
```

What it does while running:

- Watches the PoolManager for swaps in your pool, attributing each to the wallet behind it.
- Keeps a sliding window per wallet and scores it: a trained model plus a hard rule for
  unmistakable directional bursts.
- When a wallet crosses the threshold, signs an EIP-712 attestation and submits it. The
  score is live on-chain seconds later and every Glyph pool prices it immediately.

Useful knobs in `.env` (sane defaults included): poll cadence, burst window and gap,
submit threshold, and a list of wallets to never score. Safety is built in: the keeper
only ever raises scores (decay handles recovery), refuses to re-sign the same nonce, and
rate-limits the attestor key. One-off scoring without the loop:
`python -m detector.run --wallet 0x… --submit`.

---

## I'm a developer integrating the registry

The registry is a freestanding contract anyone can read. Three calls cover most uses:

```solidity
IReputationRegistry registry = IReputationRegistry(REGISTRY_ADDRESS);

uint16 score = registry.scoreOf(wallet);        // current, decay-adjusted, 0..10_000
ScoreData memory d = registry.scoreDataOf(wallet); // raw value, updatedAt, nonce
```

- `scoreOf` is the number to act on. It already includes the 7-day linear decay, so you
  never need to compute it yourself.
- Events to index: `ScoreUpdated(wallet, value, nonce)` for attestations,
  `ToxicTradeReported(wallet, pool, severity, timestamp)` for in-pool reports.
- Score bands the hook uses, if you want consistent semantics: 0 is clean, up to 2,500 is
  low risk, up to 7,500 is medium, above that is high. The fee curve mapping lives in
  `ToxicityScoring.sol` and is mirrored in the frontend's `lib/format.ts`.

Write access is intentionally closed (allow-listed attestors, authorized hooks, and the
Reactive adapter). If you want your protocol's signals feeding the registry, that is an
attestor conversation, not a code change.

---

## Running the full demo yourself

The complete loop — clean trader, attack, autonomous flag, fee jump, LP payout — is
scripted and takes about three minutes to run or record.
Follow [DEMO_SCRIPT.md](DEMO_SCRIPT.md) step by step; it includes the terminal layout,
funding commands for fresh wallets, and the exact numbers you should expect to see.

## Troubleshooting

- **Dashboard shows nothing.** Check `frontend/.env.local` has the registry and hook
  addresses; the page tells you exactly which variables it wants if they're missing.
- **"No wallet found" when connecting.** Install MetaMask (or any injected wallet) and
  reload. Mobile wallet apps need WalletConnect, which isn't wired in yet.
- **Wrong network.** Use the "Switch network" state of the connect button; it adds the
  chain to your wallet if it's not there.
- **Keeper exits immediately.** It names the missing env var on stderr. Most often it's
  `ATTESTOR_PRIVATE_KEY` or `POOL_MANAGER_ADDRESS`.
- **Bot swaps fail with nonce errors.** The public RPC's nodes can lag each other; the
  demo bots already track nonces locally, so just rerun. If it persists, point `RPC_URL`
  at a dedicated endpoint.
