# Brevis ZK Circuit

Brevis App circuit for proving historical `ToxicTradeReported` events per wallet.

## What it proves

Given a wallet address, the circuit:
1. Filters `ToxicTradeReported` events where `topic1 == wallet` over the last N blocks.
2. Sums `localSeverity` from the data payload.
3. Normalizes to `[0, 10_000]` (capped at max).
4. Outputs a single uint16 value verified on-chain by the Brevis verifier.

## Setup

- SDK: Brevis Go SDK (see https://coprocessor-docs.brevis.network/)
- Circuit entry point: `circuit/main.go`
- On-chain verifier: deployed on Unichain Sepolia (address in `.env`)

## TODO

- [ ] Initialize Go module (`go mod init`)
- [ ] Implement `circuit/main.go`
- [ ] Deploy Brevis app on Kopli testnet
- [ ] Wire output into `features.py → extract_from_brevis()`
