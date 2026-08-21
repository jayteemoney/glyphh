// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {RebateVault} from "../src/RebateVault.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";

contract RebateVaultTest is Test {
    address constant OWNER = address(0xD1);
    address constant HOOK = address(0xC1);
    address constant VICTIM = address(0xF1);
    address constant OTHER = address(0xB0B);

    RebateVault vault;
    MockERC20 tokenA;
    MockERC20 tokenB;
    Currency curA;
    Currency curB;
    Currency native;

    function setUp() public {
        vault = new RebateVault(OWNER);
        vm.prank(OWNER);
        vault.setHook(HOOK, true);

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        curA = Currency.wrap(address(tokenA));
        curB = Currency.wrap(address(tokenB));
        native = CurrencyLibrary.ADDRESS_ZERO;
    }

    /// @dev Mirrors how the hook funds the vault: transfer first, attribute second.
    function _fundAndCredit(Currency c, address victim, uint256 amount) internal {
        MockERC20(Currency.unwrap(c)).mint(address(vault), amount);
        vm.prank(HOOK);
        vault.credit(c, victim, amount);
    }

    // ── Authorization ────────────────────────────────────────────────────────

    function test_credit_RevertWhenNotHook() public {
        tokenA.mint(address(vault), 1e18);
        vm.expectRevert(IRebateVault.Unauthorized.selector);
        vault.credit(curA, VICTIM, 1e18);
    }

    function test_setHook_RevertWhenNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vault.setHook(OTHER, true);
    }

    function test_setHook_togglesAuthorization() public {
        vm.prank(OWNER);
        vault.setHook(OTHER, true);
        assertTrue(vault.isAuthorizedHook(OTHER));
        vm.prank(OWNER);
        vault.setHook(OTHER, false);
        assertFalse(vault.isAuthorizedHook(OTHER));
    }

    // ── Solvency ─────────────────────────────────────────────────────────────

    /// @dev The vault refuses to attribute funds it does not hold. A hook that miscomputes a
    ///      delta fails here, in its own tests, rather than creating a claim that silently
    ///      cannot be honoured later.
    function test_credit_RevertWhenUnfunded() public {
        vm.prank(HOOK);
        vm.expectRevert(RebateVault.InsufficientBalance.selector);
        vault.credit(curA, VICTIM, 1e18);
    }

    function test_credit_RevertWhenOverAttributingExistingBalance() public {
        _fundAndCredit(curA, VICTIM, 1e18);
        vm.prank(HOOK);
        vm.expectRevert(RebateVault.InsufficientBalance.selector);
        vault.credit(curA, OTHER, 1);
    }

    function test_credit_zeroIsNoop() public {
        vm.prank(HOOK);
        vault.credit(curA, VICTIM, 0);
        assertEq(vault.claimable(VICTIM, curA), 0);
        assertEq(vault.outstanding(curA), 0);
    }

    // ── Credit and claim ─────────────────────────────────────────────────────

    function test_credit_updatesLedger() public {
        _fundAndCredit(curA, VICTIM, 3e18);
        assertEq(vault.claimable(VICTIM, curA), 3e18);
        assertEq(vault.outstanding(curA), 3e18);
    }

    function test_credit_emitsEvent() public {
        tokenA.mint(address(vault), 2e18);
        vm.expectEmit(true, true, true, true);
        emit IRebateVault.RebateCredited(VICTIM, curA, 2e18, HOOK);
        vm.prank(HOOK);
        vault.credit(curA, VICTIM, 2e18);
    }

    function test_claim_transfersAndZeroes() public {
        _fundAndCredit(curA, VICTIM, 5e18);

        vm.prank(VICTIM);
        uint256 got = vault.claim(curA);

        assertEq(got, 5e18);
        assertEq(tokenA.balanceOf(VICTIM), 5e18);
        assertEq(vault.claimable(VICTIM, curA), 0);
        assertEq(vault.outstanding(curA), 0);
    }

    function test_claim_RevertWhenNothingToClaim() public {
        vm.prank(VICTIM);
        vm.expectRevert(IRebateVault.NothingToClaim.selector);
        vault.claim(curA);
    }

    function test_claim_RevertOnSecondClaim() public {
        _fundAndCredit(curA, VICTIM, 1e18);
        vm.prank(VICTIM);
        vault.claim(curA);
        vm.prank(VICTIM);
        vm.expectRevert(IRebateVault.NothingToClaim.selector);
        vault.claim(curA);
    }

    function test_creditsAccumulateAcrossSandwiches() public {
        _fundAndCredit(curA, VICTIM, 1e18);
        _fundAndCredit(curA, VICTIM, 2e18);
        assertEq(vault.claimable(VICTIM, curA), 3e18);
    }

    // ── Isolation ────────────────────────────────────────────────────────────

    function test_currenciesSettleIndependently() public {
        _fundAndCredit(curA, VICTIM, 1e18);
        _fundAndCredit(curB, VICTIM, 7e18);

        vm.prank(VICTIM);
        vault.claim(curA);

        assertEq(vault.claimable(VICTIM, curA), 0);
        assertEq(vault.claimable(VICTIM, curB), 7e18);
        assertEq(tokenB.balanceOf(VICTIM), 0);
    }

    function test_victimsSettleIndependently() public {
        _fundAndCredit(curA, VICTIM, 1e18);
        _fundAndCredit(curA, OTHER, 4e18);

        vm.prank(VICTIM);
        vault.claim(curA);

        assertEq(tokenA.balanceOf(VICTIM), 1e18);
        assertEq(vault.claimable(OTHER, curA), 4e18);
        assertEq(vault.outstanding(curA), 4e18);
    }

    function test_oneVictimCannotDrainAnother() public {
        _fundAndCredit(curA, OTHER, 9e18);
        vm.prank(VICTIM);
        vm.expectRevert(IRebateVault.NothingToClaim.selector);
        vault.claim(curA);
    }

    // ── Native currency ──────────────────────────────────────────────────────

    function test_nativeCurrency_creditAndClaim() public {
        vm.deal(address(vault), 3 ether);
        vm.prank(HOOK);
        vault.credit(native, VICTIM, 3 ether);

        uint256 before = VICTIM.balance;
        vm.prank(VICTIM);
        vault.claim(native);
        assertEq(VICTIM.balance - before, 3 ether);
    }

    // ── Invariant-flavoured fuzz ─────────────────────────────────────────────

    /// @dev However credits are split across victims, the vault can never pay out more than
    ///      it was funded with.
    function testFuzz_claimedNeverExceedsCredited(uint96 a, uint96 b) public {
        uint256 amtA = bound(a, 1, 1e24);
        uint256 amtB = bound(b, 1, 1e24);

        _fundAndCredit(curA, VICTIM, amtA);
        _fundAndCredit(curA, OTHER, amtB);

        vm.prank(VICTIM);
        uint256 gotA = vault.claim(curA);
        vm.prank(OTHER);
        uint256 gotB = vault.claim(curA);

        assertEq(gotA + gotB, amtA + amtB);
        assertEq(tokenA.balanceOf(address(vault)), 0);
        assertEq(vault.outstanding(curA), 0);
    }
}
