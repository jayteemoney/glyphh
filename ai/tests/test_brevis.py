"""
Brevis ZK-history read path: prefer the ZK-proven value, fall back to None.

`extract_from_brevis` returns the on-chain `histToxScore` only when a proof has
actually been submitted for the wallet (`provenAt > 0`), normalised to [0, 1];
otherwise it returns None so the caller falls back to the RPC event scan. It must
never fabricate a value or crash when the consumer is unconfigured.
"""

import os

import pytest
from web3 import Web3


class _FakeContract:
    def __init__(self, hist: int, proven_at: int):
        self._hist = hist
        self._proven_at = proven_at

    @property
    def functions(self):
        return self

    def histToxScore(self, _wallet):
        return _Ret(self._hist)

    def provenAt(self, _wallet):
        return _Ret(self._proven_at)


class _Ret:
    def __init__(self, value):
        self._value = value

    def call(self):
        return self._value


def _patch_brevis(hist: int, proven_at: int, monkeypatch):
    import detector.brevis as brevis
    monkeypatch.setenv("BREVIS_CONSUMER_ADDRESS", Web3.to_checksum_address("0x" + "11" * 20))

    class _FakeW3:
        def __init__(self, *_):
            pass

        @property
        def eth(self):
            return self

        def contract(self, **kwargs):
            return _FakeContract(hist, proven_at)

    # A class that behaves like web3.Web3 for the read path: callable constructor,
    # with the real `to_checksum_address` preserved on the class (extract_from_brevis
    # calls Web3.to_checksum_address).
    class _FakeWeb3:
        to_checksum_address = staticmethod(Web3.to_checksum_address)

        class HTTPProvider:
            def __init__(self, *a, **k):
                pass

        def __new__(cls, *_a, **_k):
            return _FakeW3()

    monkeypatch.setattr(brevis, "Web3", _FakeWeb3)
    return brevis


def test_none_when_not_configured(monkeypatch):
    monkeypatch.delenv("BREVIS_CONSUMER_ADDRESS", raising=False)
    from detector.brevis import extract_from_brevis
    assert extract_from_brevis(Web3.to_checksum_address("0x" + "22" * 20)) is None


def test_none_when_no_proof_yet(monkeypatch):
    brevis = _patch_brevis(hist=5000, proven_at=0, monkeypatch=monkeypatch)
    assert brevis.extract_from_brevis(Web3.to_checksum_address("0x" + "22" * 20)) is None


def test_returns_normalised_score_when_proven(monkeypatch):
    brevis = _patch_brevis(hist=2500, proven_at=999, monkeypatch=monkeypatch)
    got = brevis.extract_from_brevis(Web3.to_checksum_address("0x" + "22" * 20))
    assert got == pytest.approx(0.25)
    assert 0.0 <= got <= 1.0


def test_clamps_at_one(monkeypatch):
    brevis = _patch_brevis(hist=40_000, proven_at=1, monkeypatch=monkeypatch)
    assert brevis.extract_from_brevis(Web3.to_checksum_address("0x" + "22" * 20)) == 1.0


def test_never_raises_when_read_fails(monkeypatch):
    import detector.brevis as brevis
    monkeypatch.setenv("BREVIS_CONSUMER_ADDRESS", Web3.to_checksum_address("0x" + "11" * 20))

    def _boom(*a, **k):
        raise RuntimeError("rpc down")

    monkeypatch.setattr(brevis, "Web3", _boom)
    assert brevis.extract_from_brevis(Web3.to_checksum_address("0x" + "22" * 20)) is None
