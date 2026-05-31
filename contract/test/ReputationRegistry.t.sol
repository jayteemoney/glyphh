// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";

contract ReputationRegistryTest is Test {
    uint256 constant ATTESTOR_PK = 0xA11CE;
    address immutable ATTESTOR   = vm.addr(0xA11CE);
    address constant OWNER       = address(0xD1);
    address constant WALLET      = address(0xB1);
    address constant HOOK        = address(0xC1);
    address constant PROXY       = address(0xE1);

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
        bytes32 structHash = keccak256(
            abi.encode(domainSep, a.wallet, a.value, a.nonce, a.deadline)
        );
        // Use the registry's exposed domain via eip712Domain().
        (
            , string memory name, string memory version,
            uint256 chainId, address verifyingContract,,
        ) = registry.eip712Domain();
        bytes32 domainHash = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            chainId,
            verifyingContract
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainHash, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _attestation(uint16 value, uint32 nonce) internal view returns (IReputationRegistry.Attestation memory) {
        IReputationRegistry.Attestation memory a;
        a.wallet   = WALLET;
        a.value    = value;
        a.nonce    = nonce;
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
}
