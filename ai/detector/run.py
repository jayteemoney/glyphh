"""
run.py — CLI entry point for the Glyph off-chain ML detector.

Usage:
  python -m detector.run --wallet 0xABCD...           # dry-run, prints attestation
  python -m detector.run --wallet 0xABCD... --submit  # sign + submit on-chain

Exit codes: 0 = success, 1 = any unexpected error.
"""

from __future__ import annotations

import argparse
import json
import sys
import os

from dotenv import load_dotenv
from web3 import Web3

load_dotenv()


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Glyph off-chain reputation scorer")
    p.add_argument("--wallet", required=True, help="Wallet address to score")
    p.add_argument("--submit", action="store_true", help="Submit attestation on-chain")
    p.add_argument("--verbose", action="store_true", help="Print feature vector")
    return p.parse_args()


def main() -> None:
    args = _parse_args()

    # Validate address
    try:
        wallet = Web3.to_checksum_address(args.wallet)
    except Exception:
        print(f"ERROR: invalid wallet address: {args.wallet}", file=sys.stderr)
        sys.exit(1)

    # Lazy imports keep startup fast and errors local
    from detector.features import extract_features, fetch_current_nonce
    from detector.model    import score
    from detector.attestor import sign_attestation, attestation_to_dict

    print(f"Scoring wallet: {wallet}")

    # 1. Extract features
    print("Extracting features...", flush=True)
    features = extract_features(wallet)
    if args.verbose:
        print("Features:")
        for k, v in features.items():
            print(f"  {k:24s} {v:.4f}")

    # 2. Score
    reputation_score = score(features)
    print(f"Reputation score:  {reputation_score} / 10000  ({reputation_score / 100:.2f}%)")

    # 3. Read on-chain nonce
    nonce = fetch_current_nonce(wallet) + 1
    print(f"Using nonce:       {nonce}")

    # 4. Sign attestation
    if "ATTESTOR_PRIVATE_KEY" not in os.environ:
        print("ERROR: ATTESTOR_PRIVATE_KEY not set in environment.", file=sys.stderr)
        sys.exit(1)

    attestation = sign_attestation(wallet, reputation_score, nonce)
    attestation_dict = attestation_to_dict(attestation)

    print("\nAttestation:")
    print(json.dumps(attestation_dict, indent=2))

    # 5. Optionally submit on-chain
    if args.submit:
        _submit(attestation_dict)
    else:
        print("\nDry-run complete. Pass --submit to send on-chain.")


def _submit(attestation: dict) -> None:
    """Submit the signed attestation to ReputationRegistry.updateScore()."""
    from web3 import Web3

    rpc           = os.environ.get("RPC_URL", "https://sepolia.unichain.org")
    registry_addr = os.environ.get("REGISTRY_ADDRESS", "")
    private_key   = os.environ["ATTESTOR_PRIVATE_KEY"]

    if not registry_addr:
        print("ERROR: REGISTRY_ADDRESS not set.", file=sys.stderr)
        sys.exit(1)

    w3      = Web3(Web3.HTTPProvider(rpc))
    account = w3.eth.account.from_key(private_key)

    abi = [
        {
            "name": "updateScore",
            "type": "function",
            "inputs": [
                {
                    "name": "attestation",
                    "type": "tuple",
                    "components": [
                        {"name": "wallet",    "type": "address"},
                        {"name": "value",     "type": "uint16"},
                        {"name": "nonce",     "type": "uint32"},
                        {"name": "deadline",  "type": "uint64"},
                        {"name": "signature", "type": "bytes"},
                    ],
                }
            ],
            "outputs": [],
            "stateMutability": "nonpayable",
        }
    ]

    registry = w3.eth.contract(
        address=Web3.to_checksum_address(registry_addr),
        abi=abi,
    )

    sig_bytes = bytes.fromhex(attestation["signature"][2:])

    tx = registry.functions.updateScore((
        attestation["wallet"],
        attestation["value"],
        attestation["nonce"],
        attestation["deadline"],
        sig_bytes,
    )).build_transaction({
        "from":  account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas":   200_000,
    })

    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"\nSubmitted tx: {tx_hash.hex()}")

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    if receipt["status"] == 1:
        print(f"Confirmed in block {receipt['blockNumber']}. Score updated on-chain.")
    else:
        print("Transaction reverted.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
