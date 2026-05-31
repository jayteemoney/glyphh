"""
attestor.py — Build and sign a Glyph score attestation using EIP-712.

The signed attestation matches the Solidity struct exactly:
  Score(address wallet, uint16 value, uint32 nonce, uint64 deadline)

Domain:
  name:              "GlyphReputationRegistry"
  version:           "1"
  chainId:           from CHAIN_ID env (default 1301 = Unichain Sepolia)
  verifyingContract: REGISTRY_ADDRESS env
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass

from eth_account import Account
from eth_account.messages import encode_typed_data
from eth_account.signers.local import LocalAccount
from web3 import Web3

from dotenv import load_dotenv

load_dotenv()


@dataclass
class Attestation:
    wallet:    str    # checksum address
    value:     int    # 0..10_000
    nonce:     int    # strictly monotonic per wallet
    deadline:  int    # unix timestamp
    signature: bytes  # 65-byte ECDSA sig


def sign_attestation(wallet: str, score: int, nonce: int) -> Attestation:
    """
    Sign a score attestation for *wallet* and return the Attestation dataclass.

    Raises ValueError if the recovered signer does not match the attestor key.
    Never logs the private key.
    """
    private_key = os.environ["ATTESTOR_PRIVATE_KEY"]
    account: LocalAccount = Account.from_key(private_key)

    chain_id       = int(os.environ.get("CHAIN_ID", "1301"))
    registry_addr  = os.environ.get("REGISTRY_ADDRESS", "")
    deadline_secs  = int(os.environ.get("DEADLINE_SECONDS", "600"))
    deadline       = int(time.time()) + deadline_secs

    wallet_cs = Web3.to_checksum_address(wallet)

    typed_data = {
        "types": {
            "EIP712Domain": [
                {"name": "name",              "type": "string"},
                {"name": "version",           "type": "string"},
                {"name": "chainId",           "type": "uint256"},
                {"name": "verifyingContract", "type": "address"},
            ],
            "Score": [
                {"name": "wallet",   "type": "address"},
                {"name": "value",    "type": "uint16"},
                {"name": "nonce",    "type": "uint32"},
                {"name": "deadline", "type": "uint64"},
            ],
        },
        "primaryType": "Score",
        "domain": {
            "name":              "GlyphReputationRegistry",
            "version":           "1",
            "chainId":           chain_id,
            "verifyingContract": registry_addr or "0x" + "0" * 40,
        },
        "message": {
            "wallet":   wallet_cs,
            "value":    score,
            "nonce":    nonce,
            "deadline": deadline,
        },
    }

    signed    = account.sign_typed_data(full_message=typed_data)
    sig_bytes = signed.signature

    # Verify the sig recovers to our attestor before returning
    recovered = Account.recover_message(
        encode_typed_data(full_message=typed_data),
        signature=sig_bytes,
    )
    if recovered.lower() != account.address.lower():
        raise ValueError(
            f"Signature verification failed: recovered {recovered}, "
            f"expected {account.address}"
        )

    return Attestation(
        wallet=wallet_cs,
        value=score,
        nonce=nonce,
        deadline=deadline,
        signature=sig_bytes,
    )


def attestation_to_dict(a: Attestation) -> dict:
    """Serialise an Attestation to a plain dict for printing or on-chain submission."""
    return {
        "wallet":    a.wallet,
        "value":     a.value,
        "nonce":     a.nonce,
        "deadline":  a.deadline,
        "signature": "0x" + a.signature.hex(),
    }
