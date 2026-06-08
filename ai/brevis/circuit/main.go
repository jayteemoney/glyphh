// Command brevis-history runs the Glyph historical-toxicity circuit as a Brevis
// prover gRPC service. The detector (ai/detector) submits a wallet + its
// ToxicTradeReported receipts; this service returns a proof that the Brevis
// network relays on-chain to GlyphHistoryConsumer.
//
// Run:
//
//	export REGISTRY_ADDRESS=0x...        # deployed ReputationRegistry
//	go run . -port 33247
//
// The event signature hash is fixed; the registry address is deployment-specific
// and injected here so the circuit binary is self-contained per environment.
package main

import (
	"encoding/hex"
	"flag"
	"log"
	"os"
	"strings"

	"github.com/brevis-network/brevis-sdk/prover"
	"golang.org/x/crypto/sha3"
)

// Wired into the circuit at build time (see app_circuit.go).
var (
	registryAddr     uint64   // low bytes of the registry address (see note below)
	toxicTradeEventID [32]byte // keccak256("ToxicTradeReported(address,address,uint16,uint256)")
)

func main() {
	port := flag.Int("port", 33247, "prover gRPC port")
	flag.Parse()

	// keccak256 of the canonical event signature -> topic0.
	toxicTradeEventID = keccak256([]byte("ToxicTradeReported(address,address,uint16,uint256)"))
	log.Printf("ToxicTradeReported topic0 = 0x%s", hex.EncodeToString(toxicTradeEventID[:]))

	// Registry address: a 20-byte address does not fit a single circuit field as a
	// raw uint, so app_circuit.go compares against it via sdk.ConstUint248. For the
	// reference build we load it from env and the circuit treats it as a Uint248.
	regHex := strings.TrimPrefix(os.Getenv("REGISTRY_ADDRESS"), "0x")
	if regHex == "" {
		log.Fatal("REGISTRY_ADDRESS not set")
	}
	// NOTE: registryAddr is consumed by the circuit as the full address value; the
	// uint64 here is a placeholder for the reference scaffold. In a real build,
	// pass the address bytes through sdk.ConstFromBigEndianBytes (see README).

	service, err := prover.NewService(&AppCircuit{}, prover.ServiceConfig{
		SetupDir: "$HOME/.brevis/setup",
		SrsDir:   "$HOME/.brevis/srs",
	})
	if err != nil {
		log.Fatalf("prover.NewService: %v", err)
	}

	log.Printf("Glyph Brevis history prover listening on :%d (registry %s)", *port, regHex)
	if err := service.Serve("", uint(*port)); err != nil {
		log.Fatalf("serve: %v", err)
	}
}

func keccak256(b []byte) [32]byte {
	h := sha3.NewLegacyKeccak256()
	h.Write(b)
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out
}
