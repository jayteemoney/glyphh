module github.com/glyph/brevis-history

// Glyph historical-toxicity ZK circuit (Brevis App SDK).
//
// Pin note: the Brevis SDK surface (sdk.CircuitAPI, sdk.DataStream helpers) is
// stable in shape but method names have shifted across minor versions. These are
// the versions this circuit was written against; bump together and re-run
// `go test ./...` if you upgrade.
go 1.21

require (
	github.com/brevis-network/brevis-sdk v0.4.0
	github.com/consensys/gnark v0.11.0
)
