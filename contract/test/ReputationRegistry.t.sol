// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";
import {IGlyphRegistry} from "../src/interfaces/IGlyphRegistry.sol";

contract ReputationRegistryTest is Test {
    uint256 constant ATTESTOR_PK = 0xA11CE;
    address immutable ATTESTOR = vm.addr(0xA11CE);
    address constant OWNER = address(0xD1);
    address constant WALLET = address(0xB1);
    address constant HOOK = address(0xC1);
    address constant PROXY = address(0xE1);

    ReputationRegistry registry;

    function setUp() public {
        registry = new ReputationRegistry(OWNER);
        vm.startPrank(OWNER);
        registry.setAttestor(ATTESTOR, true);
        registry.setHook(HOOK, true);
        registry.setReactiveProxy(PROXY);
        vm.stopPrank();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _sign(IReputationRegistry.Attestation memory a) internal view returns (bytes memory) {
        bytes32 domainSep = registry.SCORE_TYPEHASH();
        // Build the EIP-712 digest the same way the contract does.
        bytes32 structHash = keccak256(abi.encode(domainSep, a.wallet, a.value, a.nonce, a.deadline));
        // Use the registry's exposed domain via eip712Domain().
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            registry.eip712Domain();
        bytes32 domainHash = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainHash, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _attestation(uint16 value, uint32 nonce) internal view returns (IReputationRegistry.Attestation memory) {
        IReputationRegistry.Attestation memory a;
        a.wallet = WALLET;
        a.value = value;
        a.nonce = nonce;
        a.deadline = uint64(block.timestamp + 600);
        a.signature = _sign(a);
        return a;
    }

    // ── updateScore happy path ────────────────────────────────────────────────

    function test_updateScore_storesScore() public {
        IReputationRegistry.Attestation memory a = _attestation(5_000, 1);
        registry.updateScore(a);
        assertEq(registry.scoreOf(WALLET), 5_000);
    }

    function test_updateScore_emitsScoreUpdated() public {
        IReputationRegistry.Attestation memory a = _attestation(3_000, 1);
        vm.expectEmit(true, false, false, true);
        emit IReputationRegistry.ScoreUpdated(WALLET, 3_000, 1);
        registry.updateScore(a);
    }

    function test_updateScore_nonceAdvances() public {
        registry.updateScore(_attestation(1_000, 1));
        IReputationRegistry.Score memory s = registry.scoreDataOf(WALLET);
        assertEq(s.nonce, 1);

        registry.updateScore(_attestation(2_000, 2));
        s = registry.scoreDataOf(WALLET);
        assertEq(s.nonce, 2);
        assertEq(s.value, 2_000);
    }

    // ── updateScore failure paths ────────────────────────────────────────────

    function test_updateScore_RevertWhenDeadlineExpired() public {
        IReputationRegistry.Attestation memory a = _attestation(1_000, 1);
        a.deadline = uint64(block.timestamp - 1);
        a.signature = _sign(a);
        vm.expectRevert(IReputationRegistry.ExpiredDeadline.selector);
        registry.updateScore(a);
    }

    function test_updateScore_RevertWhenNonceReused() public {
        registry.updateScore(_attestation(1_000, 1));
        IReputationRegistry.Attestation memory replay = _attestation(2_000, 1);
        vm.expectRevert(IReputationRegistry.NonceTooLow.selector);
        registry.updateScore(replay);
    }

    function test_updateScore_RevertWhenNonceTooLow() public {
        registry.updateScore(_attestation(1_000, 1));
        IReputationRegistry.Attestation memory a = _attestation(500, 1);
        vm.expectRevert(IReputationRegistry.NonceTooLow.selector);
        registry.updateScore(a);
    }

    function test_updateScore_RevertWhenInvalidSignature() public {
        IReputationRegistry.Attestation memory a = _attestation(1_000, 1);
        // Corrupt the signature.
        a.signature[0] = a.signature[0] ^ 0xFF;
        vm.expectRevert();
        registry.updateScore(a);
    }

    function test_updateScore_RevertWhenScoreOutOfRange() public {
        IReputationRegistry.Attestation memory a = _attestation(10_001, 1);
        a.signature = _sign(a);
        vm.expectRevert(IReputationRegistry.ScoreOutOfRange.selector);
        registry.updateScore(a);
    }

    // ── reportToxicTrade ─────────────────────────────────────────────────────

    function test_reportToxicTrade_bumpsScore() public {
        vm.prank(HOOK);
        registry.reportToxicTrade(WALLET, address(0x1), 2_000);
        assertGt(registry.scoreOf(WALLET), 0);
    }

    function test_reportToxicTrade_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IReputationRegistry.ToxicTradeReported(WALLET, address(0x1), 2_000, block.timestamp);
        vm.prank(HOOK);
        registry.reportToxicTrade(WALLET, address(0x1), 2_000);
    }

    function test_reportToxicTrade_capsAtMax() public {
        // Report 30 times with max severity so score can't exceed 10_000.
        vm.startPrank(HOOK);
        for (uint256 i = 0; i < 30; i++) {
            registry.reportToxicTrade(WALLET, address(0x1), 10_000);
        }
        vm.stopPrank();
        assertLe(registry.scoreOf(WALLET), 10_000);
    }

    function test_reportToxicTrade_RevertWhenUnauthorized() public {
        vm.expectRevert(IReputationRegistry.Unauthorized.selector);
        registry.reportToxicTrade(WALLET, address(0x1), 500);
    }

    // ── updateScoreFromReactive ──────────────────────────────────────────────

    function test_updateScoreFromReactive_setsScore() public {
        vm.prank(PROXY);
        registry.updateScoreFromReactive(WALLET, 7_000);
        assertEq(registry.scoreOf(WALLET), 7_000);
    }

    function test_updateScoreFromReactive_doesNotLowerScore() public {
        registry.updateScore(_attestation(8_000, 1));
        vm.prank(PROXY);
        registry.updateScoreFromReactive(WALLET, 3_000);
        assertEq(registry.scoreOf(WALLET), 8_000);
    }

    function test_updateScoreFromReactive_RevertWhenNotProxy() public {
        vm.expectRevert(IReputationRegistry.Unauthorized.selector);
        registry.updateScoreFromReactive(WALLET, 5_000);
    }

    function test_updateScoreFromReactive_RevertWhenScoreOutOfRange() public {
        vm.prank(PROXY);
        vm.expectRevert(IReputationRegistry.ScoreOutOfRange.selector);
        registry.updateScoreFromReactive(WALLET, 10_001);
    }

    // ── Owner admin ──────────────────────────────────────────────────────────

    function test_setHook_emitsEvent() public {
        address newHook = address(0xF1);
        vm.expectEmit(true, false, false, true);
        emit IReputationRegistry.HookAuthorized(newHook, true);
        vm.prank(OWNER);
        registry.setHook(newHook, true);
    }

    function test_setHook_RevertWhenNotOwner() public {
        vm.expectRevert();
        registry.setHook(address(0xF1), true);
    }

    function test_setAttestor_RevertWhenNotOwner() public {
        vm.expectRevert();
        registry.setAttestor(address(0xF1), true);
    }

    function test_isAuthorizedHook_returnsTrue() public view {
        assertTrue(registry.isAuthorizedHook(HOOK));
    }

    function test_isAuthorizedHook_returnsFalse() public view {
        assertFalse(registry.isAuthorizedHook(address(0xDEAD)));
    }

    // ── Invariants ───────────────────────────────────────────────────────────

    function test_scoreNeverExceedsMax(uint16 val) public {
        vm.assume(val <= 10_000);
        registry.updateScore(_attestation(val, 1));
        assertLe(registry.scoreOf(WALLET), 10_000);
    }

    // ── Decay ──────────────────────────────────────────────────────────────────

    function _attestationFor(address w, uint16 value, uint32 nonce)
        internal
        view
        returns (IReputationRegistry.Attestation memory a)
    {
        a.wallet = w;
        a.value = value;
        a.nonce = nonce;
        a.deadline = uint64(block.timestamp + 600);
        a.signature = _sign(a);
    }

    function test_decay_freshScoreIsFull() public {
        registry.updateScore(_attestation(8_000, 1));
        assertEq(registry.scoreOf(WALLET), 8_000);
    }

    function test_decay_halfPeriodHalvesScore() public {
        registry.updateScore(_attestation(10_000, 1));
        vm.warp(block.timestamp + registry.DECAY_PERIOD() / 2);
        assertEq(registry.scoreOf(WALLET), 5_000);
    }

    function test_decay_fullPeriodZeroesScore() public {
        registry.updateScore(_attestation(10_000, 1));
        vm.warp(block.timestamp + registry.DECAY_PERIOD());
        assertEq(registry.scoreOf(WALLET), 0);
    }

    function test_decay_rawValueUnaffected() public {
        registry.updateScore(_attestation(8_000, 1));
        vm.warp(block.timestamp + registry.DECAY_PERIOD() / 2);
        assertEq(registry.scoreOf(WALLET), 4_000); // decayed
        assertEq(registry.scoreDataOf(WALLET).value, 8_000); // raw
    }

    function test_reportToxicTrade_rebaselinesDecayedValue() public {
        vm.prank(HOOK);
        registry.reportToxicTrade(WALLET, address(0x1), 10_000); // value -> 5_000
        assertEq(registry.scoreOf(WALLET), 5_000);

        vm.warp(block.timestamp + registry.DECAY_PERIOD()); // fully decays
        assertEq(registry.scoreOf(WALLET), 0);

        vm.prank(HOOK);
        registry.reportToxicTrade(WALLET, address(0x1), 200); // base 0 + 100, not resurrected
        assertEq(registry.scoreOf(WALLET), 100);
    }

    // ── Batch ──────────────────────────────────────────────────────────────────

    function test_updateScoreBatch_appliesAll() public {
        address w2 = address(0xB2);
        IReputationRegistry.Attestation[] memory batch = new IReputationRegistry.Attestation[](2);
        batch[0] = _attestationFor(WALLET, 1_000, 1);
        batch[1] = _attestationFor(w2, 2_000, 1);
        registry.updateScoreBatch(batch);
        assertEq(registry.scoreOf(WALLET), 1_000);
        assertEq(registry.scoreOf(w2), 2_000);
    }

    function test_updateScoreBatch_RevertWhenOneInvalid() public {
        IReputationRegistry.Attestation[] memory batch = new IReputationRegistry.Attestation[](2);
        batch[0] = _attestationFor(WALLET, 1_000, 1);
        batch[1] = _attestationFor(WALLET, 2_000, 1); // duplicate nonce -> NonceTooLow
        vm.expectRevert(IReputationRegistry.NonceTooLow.selector);
        registry.updateScoreBatch(batch);
        assertEq(registry.scoreOf(WALLET), 0); // atomic: nothing landed
    }

    // ── Deadline window ─────────────────────────────────────────────────────────

    function test_updateScore_RevertWhenDeadlineTooFar() public {
        IReputationRegistry.Attestation memory a = _attestation(1_000, 1);
        a.deadline = uint64(block.timestamp + registry.MAX_DEADLINE_WINDOW() + 1);
        a.signature = _sign(a);
        vm.expectRevert(ReputationRegistry.DeadlineTooFar.selector);
        registry.updateScore(a);
    }

    // ── Events + getters ────────────────────────────────────────────────────────

    function test_setAttestor_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IGlyphRegistry.AttestorAuthorized(address(0xF2), true);
        vm.prank(OWNER);
        registry.setAttestor(address(0xF2), true);
    }

    function test_setReactiveProxy_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ReputationRegistry.ReactiveProxyUpdated(address(0xF3));
        vm.prank(OWNER);
        registry.setReactiveProxy(address(0xF3));
    }

    function test_isAuthorizedAttestor() public view {
        assertTrue(registry.isAuthorizedAttestor(ATTESTOR));
        assertFalse(registry.isAuthorizedAttestor(address(0xDEAD)));
    }

    function test_domainSeparator_nonZero() public view {
        assertTrue(registry.domainSeparator() != bytes32(0));
    }

    // ── Trust helpers (v2) ───────────────────────────────────────────────────

    function _signTrust(IGlyphRegistry.TrustAttestation memory a) internal view returns (bytes memory) {
        bytes32 structHash =
            keccak256(abi.encode(registry.TRUST_TYPEHASH(), a.wallet, a.value, a.nonce, a.deadline));
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            registry.eip712Domain();
        bytes32 domainHash = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainHash, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _trustAttestation(uint16 value, uint32 nonce)
        internal
        view
        returns (IGlyphRegistry.TrustAttestation memory)
    {
        IGlyphRegistry.TrustAttestation memory a;
        a.wallet = WALLET;
        a.value = value;
        a.nonce = nonce;
        a.deadline = uint64(block.timestamp + 600);
        a.signature = _signTrust(a);
        return a;
    }

    // ── Trust: happy path ────────────────────────────────────────────────────

    function test_updateTrust_storesValue() public {
        registry.updateTrust(_trustAttestation(6_000, 1));
        assertEq(registry.trustOf(WALLET), 6_000);
        assertEq(registry.trustDataOf(WALLET).nonce, 1);
    }

    function test_updateTrust_emitsTrustUpdated() public {
        vm.expectEmit(true, false, false, true);
        emit IGlyphRegistry.TrustUpdated(WALLET, 4_200, 1);
        registry.updateTrust(_trustAttestation(4_200, 1));
    }

    function test_updateTrust_nonceAdvances() public {
        registry.updateTrust(_trustAttestation(1_000, 1));
        registry.updateTrust(_trustAttestation(2_000, 2));
        assertEq(registry.trustOf(WALLET), 2_000);
    }

    // ── Trust: authorization and replay ──────────────────────────────────────

    function test_updateTrust_RevertWhenUnauthorizedSigner() public {
        // Build the attestation before arming expectRevert: the helper itself makes external
        // calls (TRUST_TYPEHASH, eip712Domain), and expectRevert binds to the very next one.
        IGlyphRegistry.TrustAttestation memory a = _trustAttestation(5_000, 1);
        vm.prank(OWNER);
        registry.setAttestor(ATTESTOR, false);
        vm.expectRevert(IReputationRegistry.InvalidSignature.selector);
        registry.updateTrust(a);
    }

    function test_updateTrust_RevertWhenNonceReused() public {
        registry.updateTrust(_trustAttestation(5_000, 1));
        IGlyphRegistry.TrustAttestation memory replay = _trustAttestation(9_000, 1);
        vm.expectRevert(IReputationRegistry.NonceTooLow.selector);
        registry.updateTrust(replay);
    }

    function test_updateTrust_RevertWhenDeadlineExpired() public {
        IGlyphRegistry.TrustAttestation memory a = _trustAttestation(5_000, 1);
        vm.warp(block.timestamp + 601);
        vm.expectRevert(IReputationRegistry.ExpiredDeadline.selector);
        registry.updateTrust(a);
    }

    function test_updateTrust_RevertWhenDeadlineTooFar() public {
        IGlyphRegistry.TrustAttestation memory a;
        a.wallet = WALLET;
        a.value = 5_000;
        a.nonce = 1;
        a.deadline = uint64(block.timestamp + 2 hours);
        a.signature = _signTrust(a);
        vm.expectRevert(ReputationRegistry.DeadlineTooFar.selector);
        registry.updateTrust(a);
    }

    function test_updateTrust_RevertWhenOutOfRange() public {
        IGlyphRegistry.TrustAttestation memory a;
        a.wallet = WALLET;
        a.value = 10_001;
        a.nonce = 1;
        a.deadline = uint64(block.timestamp + 600);
        a.signature = _signTrust(a);
        vm.expectRevert(IReputationRegistry.ScoreOutOfRange.selector);
        registry.updateTrust(a);
    }

    /// @dev The reason trust has its own typehash: a captured score attestation must not be
    ///      replayable as a trust attestation, even though the two structs are shaped alike.
    function test_scoreAttestation_cannotBeReplayedAsTrust() public {
        IReputationRegistry.Attestation memory scoreAtt = _attestation(9_000, 1);
        IGlyphRegistry.TrustAttestation memory forged;
        forged.wallet = scoreAtt.wallet;
        forged.value = scoreAtt.value;
        forged.nonce = scoreAtt.nonce;
        forged.deadline = scoreAtt.deadline;
        forged.signature = scoreAtt.signature;

        vm.expectRevert(IReputationRegistry.InvalidSignature.selector);
        registry.updateTrust(forged);
    }

    // ── Trust: decay ─────────────────────────────────────────────────────────

    function test_trustDecay_halfwayIsHalf() public {
        registry.updateTrust(_trustAttestation(10_000, 1));
        vm.warp(block.timestamp + 15 days);
        assertEq(registry.trustOf(WALLET), 5_000);
    }

    function test_trustDecay_fullPeriodIsZero() public {
        registry.updateTrust(_trustAttestation(10_000, 1));
        vm.warp(block.timestamp + 30 days);
        assertEq(registry.trustOf(WALLET), 0);
    }

    /// @dev Trust must outlive toxicity. At 7 days a maximal toxicity score has fully decayed
    ///      while trust still has most of its value — that asymmetry is what makes rotating a
    ///      wallet expensive rather than free.
    function test_trustDecaysSlowerThanToxicity() public {
        registry.updateScore(_attestation(10_000, 1));
        registry.updateTrust(_trustAttestation(10_000, 1));
        vm.warp(block.timestamp + 7 days);
        assertEq(registry.scoreOf(WALLET), 0);
        assertGt(registry.trustOf(WALLET), 7_000);
    }

    function test_trustNeverExceedsMax(uint16 value) public {
        value = uint16(bound(value, 0, 10_000));
        registry.updateTrust(_trustAttestation(value, 1));
        assertLe(registry.trustOf(WALLET), 10_000);
    }

    // ── Pool-aware toxic reporting (v2) ──────────────────────────────────────

    function test_reportToxicSwap_emitsPoolId() public {
        bytes32 poolId = keccak256("POOL_A");
        vm.expectEmit(true, true, false, true);
        emit IGlyphRegistry.ToxicSwapReported(WALLET, poolId, 4_000, block.timestamp);
        vm.prank(HOOK);
        registry.reportToxicSwap(WALLET, poolId, 4_000);
    }

    function test_reportToxicSwap_RevertWhenNotHook() public {
        vm.expectRevert(IReputationRegistry.Unauthorized.selector);
        registry.reportToxicSwap(WALLET, keccak256("POOL_A"), 4_000);
    }

    function test_reportToxicSwap_raisesScore() public {
        vm.prank(HOOK);
        registry.reportToxicSwap(WALLET, keccak256("POOL_A"), 4_000);
        assertEq(registry.scoreOf(WALLET), 2_000);
    }

    /// @dev Score and trust are independent axes: a wallet can be both known-good historically
    ///      and toxic right now, and the fee model resolves that rather than the registry.
    function test_scoreAndTrustAreIndependent() public {
        registry.updateTrust(_trustAttestation(8_000, 1));
        vm.prank(HOOK);
        registry.reportToxicSwap(WALLET, keccak256("POOL_A"), 6_000);
        assertEq(registry.trustOf(WALLET), 8_000);
        assertEq(registry.scoreOf(WALLET), 3_000);
    }
}
