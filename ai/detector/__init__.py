"""
Glyph off-chain ML detector.

  features.py  — extract on-chain features per wallet
  model.py     — gradient-boosting scorer (0..10_000)
  attestor.py  — EIP-712 sign the score attestation
  run.py       — CLI: python -m detector.run --wallet 0x...
"""
