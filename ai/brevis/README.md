# Glyph Brevis ZK History

A [Brevis](https://coprocessor-docs.brevis.network/) coprocessor app that proves a
wallet's **historical toxicity** — the clamped sum of its past
`ToxicTradeReported.localSeverity` events — without trusting the off-chain detector.

The proven value lands on-chain in `GlyphHistoryConsumer.histToxScore[wallet]`, and the
detector reads it (`ai/detector/brevis.py → extract_from_brevis`) as the
`hist_tox_score_7d` feature. A malicious or buggy attestor therefore **cannot fabricate a
wallet's history**: the strongest historical signal is ZK-verified, not asserted.

```
ToxicTradeReported logs ──▶ Brevis prover (circuit/) ──▶ proof
                                                          │
                          Brevis network verifies ───────┘
                                   │ brevisCallback(vkHash, output)
                                   ▼
                       GlyphHistoryConsumer (contracts/)
                          histToxScore[wallet] = score
                                   ▲
                                   │ eth_call (view)
                          detector/brevis.py
```

## What the circuit proves (`circuit/app_circuit.go`)

Given a public `Wallet`, over a set of receipts the prover supplies:

1. **Authenticity** — each receipt is a `ToxicTradeReported` log from the configured
   `ReputationRegistry` (`topic0 == keccak256(sig)`, `Contract == registry`), and its
   `topic1` equals `Wallet`.
2. **Field binding** — field 0 is the indexed wallet topic; field 1 is the first
   non-indexed data word (`localSeverity`).
3. **Anti-replay** — receipts are asserted strictly increasing by block, so the same
   event can't be double-counted to inflate a victim's score.
4. **Aggregate** — `sum(localSeverity)` clamped to `MAX_SCORE` (10 000 bps).
5. **Output** — `OutputAddress(Wallet)` ‖ `OutputUint(248, score)` →
   20-byte address followed by a 31-byte uint whose low 16 bits are the score.

It is a **lower bound** by construction (the prover may omit receipts, which only lowers
the score); the live hook + Reactive aggregate already cover present-tense toxicity, so a
lower historical bound is the safe direction.

## On-chain consumer (`contracts/GlyphHistoryConsumer.sol`)

- `histToxScore(address) → uint16` and `provenAt(address) → uint64` (0 = never proven).
- `brevisCallback(bytes32 vkHash, bytes output)` — only callable by the Brevis request
  contract; checks `vkHash == approvedVkHash`, decodes the 51-byte output, stores the
  score, and emits `HistoryProven`.
- `setVkHash(bytes32)` — owner pins the approved circuit's verifying-key hash.

The base `BrevisAppBase` is inlined so the contract compiles standalone; for production,
replace it with the import from `brevis-network/brevis-contracts`
(`sdk/apps/framework/BrevisApp.sol`) — the `brevisCallback` / `handleProofResult` surface
is identical.

## Build & run the prover

```bash
cd circuit
go mod tidy
export REGISTRY_ADDRESS=0x...        # deployed ReputationRegistry
go run . -port 33247                 # starts the prover gRPC service
```

First run compiles the circuit and writes proving/verifying keys under
`~/.brevis/setup`. The verifying-key hash printed there is what you pass to
`setVkHash` on the consumer.

## Deploy the consumer

```bash
# brevisRequest = the Brevis request/verifier contract on your target chain
# (see https://docs.brevis.network deployments).
forge create ai/brevis/contracts/GlyphHistoryConsumer.sol:GlyphHistoryConsumer \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" \
  --constructor-args "$BREVIS_REQUEST_ADDRESS"

# Pin the approved circuit:
cast send "$CONSUMER_ADDRESS" "setVkHash(bytes32)" "$VK_HASH" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
```

## Wire into the detector

```bash
# ai/.env
BREVIS_CONSUMER_ADDRESS=0x...   # the deployed GlyphHistoryConsumer
```

With that set, `extract_features` prefers the ZK-proven value and only falls back to the
raw RPC event scan when no proof exists yet (`provenAt == 0`).

## Status

- [x] Circuit (`app_circuit.go`) — authenticity, field binding, anti-replay, clamp, output.
- [x] Prover entry point (`main.go`).
- [x] On-chain consumer (`contracts/GlyphHistoryConsumer.sol`) — compiles, stores, gated.
- [x] Detector read path (`detector/brevis.py`).
- [ ] Submit a live proof end-to-end on Brevis testnet (requires funded request contract).
