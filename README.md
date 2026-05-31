# Glyph

**The first Uniswap v4 hook that prices each swap by *who* is trading, not just what.**

Glyph assigns a reputation score to every wallet based on its on-chain trading history. Swaps from clean traders pay the standard 0.30% fee. Swaps from wallets with toxic history — sandwichers, arbitrageurs, MEV bots — pay up to 10%, with the excess donated directly to LPs.

## How it works

1. **Before each swap**, the hook reads the trader's reputation score from `ReputationRegistry` and sets a dynamic fee proportional to that score.
2. **Locally**, a Pyth pull-oracle checks for anomalous price impact on the current swap. Toxic swaps are flagged immediately.
3. **After the swap**, excess fees above the base rate are donated back to LPs via `PoolManager.donate()`.
4. **Cross-pool**, a Reactive Smart Contract on the Reactive Network propagates a toxic wallet's elevated score to every other Glyph pool within ~7 seconds.
5. **Off-chain**, an ML detector signs score attestations using EIP-712. Historical features are proven via a Brevis ZK coprocessor circuit.

## Repository layout

```
contract/        Foundry project — hook, registry, reactive contract
  src/
    GlyphHook.sol              Uniswap v4 hook (beforeSwap + afterSwap)
    ReputationRegistry.sol     Score storage + EIP-712 attestation verify
    reactive/GlyphReactive.sol Reactive Network RSC (cross-pool propagation)
    libraries/ToxicityScoring.sol  Pure fee curve library
    interfaces/IReputationRegistry.sol  Frozen interface seam
  test/
  script/

frontend/        Next.js dashboard (viem + wagmi)
  src/app/dashboard/           Live event feed + score table
  src/app/pools/               Pool list + swap UI

ai/
  detector/      Python ML detector (features → score → EIP-712 attestation)
  brevis/        Brevis ZK circuit for historical toxicity score
```

## Quickstart

### Contracts

```bash
cd contract
forge install
forge build
forge test -vv
```

### Frontend

```bash
cd frontend
pnpm install
pnpm dev
```

### Off-chain detector

```bash
cd ai
python3 -m venv .venv && source .venv/bin/activate
pip install -r detector/requirements.txt
python -m detector.run --wallet 0xABCD...
```

## Deployed contracts (Unichain Sepolia)

| Contract | Address |
|---|---|
| ReputationRegistry | TBD |
| GlyphHook | TBD |
| GlyphReactive (Kopli) | TBD |

## Tech stack

- **Uniswap v4** — dynamic fee hook (`beforeSwap` + `afterSwap`)
- **Pyth Network** — pull oracle for local price-impact detection
- **Reactive Network** — cross-pool score propagation via RSC callbacks
- **Brevis** — ZK coprocessor for historical on-chain feature proofs
- **OpenZeppelin** — EIP-712, ECDSA, Ownable
- **Next.js + viem + wagmi** — live monitoring dashboard

## License

MIT
