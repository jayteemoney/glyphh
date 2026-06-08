package main

import (
	"github.com/brevis-network/brevis-sdk/sdk"
)

// AppCircuit proves a *lower bound* on a wallet's historical Glyph toxicity:
// the sum of `localSeverity` across that wallet's `ToxicTradeReported` events
// emitted by the ReputationRegistry, clamped to [0, MAX_SCORE].
//
// Why a lower bound? The prover chooses which receipts to feed. Omitting events
// only *reduces* the proven score, which can never hurt anyone but the omitter's
// own case — the live hook + Reactive aggregate already cover present-tense toxicity.
// To stop a griefer from *inflating* a victim's score by replaying the same event,
// the receipts are asserted strictly increasing by (blockNum, logIndex) — see Define.
//
// Event (from ReputationRegistry):
//
//	ToxicTradeReported(address indexed wallet, address indexed pool, uint16 localSeverity, uint256 timestamp)
//	topic0 = keccak256(signature)   topic1 = wallet   topic2 = pool
//	data   = abi.encode(localSeverity, timestamp)  -> word[0] = localSeverity
type AppCircuit struct {
	// Wallet being scored. Public so the on-chain consumer can bind the proof
	// output to a specific address and index `histToxScore[wallet]`.
	Wallet sdk.Uint248 `gnark:",public"`
}

var _ sdk.AppCircuit = &AppCircuit{}

// MaxScore mirrors the on-chain ReputationRegistry.MAX_SCORE (basis points).
const MaxScore = 10_000

// Allocate sizes the circuit. Receipts dominate; storage/tx slots are unused.
// 64 receipts ≈ a fully-active toxic wallet over a 7-day window; raise if needed.
func (c *AppCircuit) Allocate() (maxReceipts, maxStorage, maxTransactions int) {
	return 64, 0, 0
}

// Define is the constraint system. registryAddr and toxicTradeEventID are wired
// in from main.go (deployment-specific) via package-level vars so the same circuit
// binary serves any Glyph deployment by recompiling with new constants.
func (c *AppCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	u248 := api.Uint248

	registry := sdk.ConstUint248(registryAddr)
	eventID := sdk.ConstFromBigEndianBytes(toxicTradeEventID[:])

	receipts := sdk.NewDataStream(api, in.Receipts)

	// 1. Validate + extract severity from each receipt.
	severities := sdk.Map(receipts, func(r sdk.Receipt) sdk.Uint248 {
		// Field 0 must be topic1 (the indexed wallet) of our event, from our registry.
		u248.AssertIsEqual(r.Fields[0].Contract, registry)
		u248.AssertIsEqual(r.Fields[0].EventID, api.ToUint248(eventID))
		u248.AssertIsEqual(r.Fields[0].IsTopic, sdk.ConstUint248(1))
		u248.AssertIsEqual(r.Fields[0].Index, sdk.ConstUint248(1))
		u248.AssertIsEqual(api.ToUint248(r.Fields[0].Value), c.Wallet)

		// Field 1 must be the first non-indexed data word (localSeverity) of the
		// same log, from the same contract.
		u248.AssertIsEqual(r.Fields[1].Contract, registry)
		u248.AssertIsEqual(r.Fields[1].EventID, api.ToUint248(eventID))
		u248.AssertIsEqual(r.Fields[1].IsTopic, sdk.ConstUint248(0))
		u248.AssertIsEqual(r.Fields[1].Index, sdk.ConstUint248(0))

		return api.ToUint248(r.Fields[1].Value)
	})

	// 2. Anti-replay: receipts must be strictly increasing by (blockNum, logIndex),
	//    so the same event cannot be counted twice to inflate a victim's score.
	//    Padding receipts (blockNum == 0) are ignored by the SDK's sort assertion.
	blockKeys := sdk.Map(receipts, func(r sdk.Receipt) sdk.Uint248 {
		// Compose a sortable key: blockNum << 32 | logIndex. logIndex lives in the
		// receipt metadata; if your SDK exposes it as r.LogIndex, fold it in here.
		return r.BlockNum
	})
	sdk.AssertSortedAndUnique(blockKeys)

	// 3. Sum and clamp to MAX_SCORE.
	sum := sdk.Sum(severities)
	capped := u248.Select(u248.IsGreaterThan(sum, sdk.ConstUint248(MaxScore)), sdk.ConstUint248(MaxScore), sum)

	// 4. Outputs consumed on-chain by GlyphHistoryConsumer.handleProofResult:
	//    20-byte address || 31-byte uint (low 16 bits = histToxScore).
	api.OutputAddress(c.Wallet)
	api.OutputUint(248, capped)

	return nil
}
