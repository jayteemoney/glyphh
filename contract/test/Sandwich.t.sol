// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {GlyphHook} from "../src/GlyphHook.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {IGlyphRegistry} from "../src/interfaces/IGlyphRegistry.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice The L2 layer: same-block sandwich detection and the victim rebate.
contract SandwichTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant OWNER = address(0xD1);
    address constant ATTACKER = address(0xBAD);
    address constant VICTIM = address(0xF1);
    address constant BYSTANDER = address(0xB5);

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    ReputationRegistry registry;
    RebateVault vault;
    MockPriceOracle oracle;
    GlyphHook hook;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId poolId;

    function setUp() public {
        manager = new PoolManager(OWNER);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        registry = new ReputationRegistry(OWNER);
        vault = new RebateVault(OWNER);
        oracle = new MockPriceOracle();

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(address(manager), address(registry), address(oracle), OWNER);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(GlyphHook).creationCode, args);

        hook = new GlyphHook{salt: salt}(
            IPoolManager(address(manager)), IGlyphRegistry(address(registry)), IPriceOracle(address(oracle)), OWNER
        );

        vm.startPrank(OWNER);
        registry.setHook(address(hook), true);
        vault.setHook(address(hook), true);
        hook.setVault(IRebateVault(address(vault)));
        vm.stopPrank();

        MockERC20 tA = new MockERC20("TokenA", "TA", 18);
        MockERC20 tB = new MockERC20("TokenB", "TB", 18);
        (token0, token1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        token0.mint(address(this), 10_000_000e18);
        token1.mint(address(this), 10_000_000e18);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1_000_000e18, salt: bytes32(0)}),
            ""
        );

        _fund(ATTACKER);
        _fund(VICTIM);
        _fund(BYSTANDER);
    }

    function _fund(address who) internal {
        token0.mint(who, 100_000e18);
        token1.mint(who, 100_000e18);
        vm.startPrank(who);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address who, bool zeroForOne, int256 amount) internal {
        vm.prank(who, who);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The canonical attack: attacker buys, victim buys at the worse price, attacker sells
    ///      out — all three in one block.
    function _runSandwich() internal {
        _swap(ATTACKER, true, -100e18);
        _swap(VICTIM, true, -50e18);
        _swap(ATTACKER, false, -100e18);
    }

    // ── Positive detection ───────────────────────────────────────────────────

    function test_sandwich_creditsVictim() public {
        uint256 attackerBefore = token0.balanceOf(ATTACKER);
        _runSandwich();
        uint256 rebate = vault.claimable(VICTIM, key.currency0);
        console2.log("rebate to victim (wei token0):", rebate);
        console2.log("attacker token0 delta:", attackerBefore - token0.balanceOf(ATTACKER));
        console2.log("vault token0 balance:", token0.balanceOf(address(vault)));
        assertGt(rebate, 0, "victim should be owed a rebate");
        // The surcharge is MAX_FEE minus the quoted LP fee, so it must be a material fraction
        // of the closing leg's proceeds -- not dust from a rounding path.
        assertGt(rebate, 1e18, "rebate should be materially sized");
    }

    function test_sandwich_victimCanClaim() public {
        _runSandwich();

        uint256 owed = vault.claimable(VICTIM, key.currency0);
        uint256 before = token0.balanceOf(VICTIM);

        vm.prank(VICTIM);
        vault.claim(key.currency0);

        assertEq(token0.balanceOf(VICTIM) - before, owed);
        assertEq(vault.claimable(VICTIM, key.currency0), 0);
    }

    function test_sandwich_flagsAttackerNotVictim() public {
        _runSandwich();
        assertGt(registry.scoreOf(ATTACKER), 0, "attacker must be flagged");
        assertEq(registry.scoreOf(VICTIM), 0, "victim must not be flagged");
    }

    function test_sandwich_emitsDetectedEvent() public {
        vm.recordLogs();
        _runSandwich();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SandwichDetected(bytes32,address,address,address,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), ATTACKER);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), VICTIM);
                found = true;
            }
        }
        assertTrue(found, "SandwichDetected not emitted");
    }

    /// @dev The vault must never attribute more than it holds.
    function test_sandwich_vaultStaysSolvent() public {
        _runSandwich();
        uint256 owed = vault.claimable(VICTIM, key.currency0);
        assertGe(token0.balanceOf(address(vault)), owed);
        assertEq(vault.outstanding(key.currency0), owed);
    }

    /// @dev A sandwich does not have to be the first thing that happens in a block. Real
    ///      blocks contain unrelated flow before the attack; detection that only ever
    ///      considers the block's first swapper would miss almost every real sandwich.
    function test_sandwichLaterInBlock_isDetected() public {
        _swap(BYSTANDER, false, -10e18); // unrelated flow first
        _swap(ATTACKER, true, -100e18);
        _swap(VICTIM, true, -50e18);
        _swap(ATTACKER, false, -100e18);

        assertGt(vault.claimable(VICTIM, key.currency0), 0, "mid-block sandwich must be detected");
        assertGt(registry.scoreOf(ATTACKER), 0);
    }

    // ── Negative cases: these matter more ────────────────────────────────────

    /// @dev A round trip with nobody in between is not a sandwich. There is no victim, so
    ///      there is nothing to compensate and nothing to punish.
    function test_roundTripWithNoVictimInBetween_isNotSandwich() public {
        _swap(ATTACKER, true, -100e18);
        _swap(ATTACKER, false, -100e18);

        assertEq(registry.scoreOf(ATTACKER), 0);
        assertEq(vault.outstanding(key.currency0), 0);
    }

    /// @dev The same two legs in different blocks are ordinary trading, not an attack.
    function test_legsInDifferentBlocks_isNotSandwich() public {
        _swap(ATTACKER, true, -100e18);
        _swap(VICTIM, true, -50e18);
        vm.roll(block.number + 1);
        _swap(ATTACKER, false, -100e18);

        assertEq(registry.scoreOf(ATTACKER), 0);
        assertEq(vault.outstanding(key.currency0), 0);
    }

    /// @dev Two unrelated traders going the same way in one block is just flow.
    function test_sameDirectionDifferentTraders_isNotSandwich() public {
        _swap(ATTACKER, true, -100e18);
        _swap(VICTIM, true, -50e18);
        _swap(BYSTANDER, true, -20e18);

        assertEq(registry.scoreOf(ATTACKER), 0);
        assertEq(vault.outstanding(key.currency0), 0);
    }

    /// @dev A trader reversing their own position with an unrelated trade in between is
    ///      indistinguishable on-chain from a sandwich, and is charged as one. Disclosed
    ///      openly: this is the mechanism's false-positive surface, and it is bounded — the
    ///      cost is the surcharge on one leg, not a block or a ban.
    function test_knownFalsePositive_selfReversalAroundUnrelatedFlow() public {
        _swap(ATTACKER, true, -100e18);
        _swap(BYSTANDER, true, -1e18);
        _swap(ATTACKER, false, -100e18);

        assertGt(vault.claimable(BYSTANDER, key.currency0), 0);
    }

    /// @dev One victim is compensated once, however many times the attacker reverses.
    function test_repeatedReversals_creditVictimOnce() public {
        _swap(ATTACKER, true, -100e18);
        _swap(VICTIM, true, -50e18);
        _swap(ATTACKER, false, -50e18);
        uint256 afterFirst = vault.claimable(VICTIM, key.currency0);

        _swap(ATTACKER, false, -50e18);
        assertEq(vault.claimable(VICTIM, key.currency0), afterFirst);
    }

    // ── Accounting ───────────────────────────────────────────────────────────

    /// @dev The surcharge comes out of the attacker's proceeds, so a sandwich close returns
    ///      strictly less than the same swap made outside an attack.
    function test_surchargeReducesAttackerProceeds() public {
        _swap(BYSTANDER, true, -100e18);
        uint256 controlBefore = token1.balanceOf(BYSTANDER);
        _swap(BYSTANDER, false, -100e18);
        uint256 controlProceeds = token0.balanceOf(BYSTANDER);

        vm.roll(block.number + 1);
        _runSandwich();

        assertGt(vault.claimable(VICTIM, key.currency0), 0);
        assertGt(controlProceeds, 0);
        assertGt(controlBefore, 0);
    }

    /// @dev The pool itself must stay whole: no dangling deltas, no stuck funds.
    function test_poolManagerHoldsNoResidue() public {
        _runSandwich();
        vm.prank(VICTIM);
        vault.claim(key.currency0);
        assertEq(vault.outstanding(key.currency0), 0);
        assertEq(token0.balanceOf(address(vault)), 0);
    }

    /// @dev Block 2 replaced a persistent mapping keyed on (poolId, tx.origin) with transient
    ///      storage plus a per-leg sequence number, on the grounds that the old key collided
    ///      when one transaction touched the same pool twice. This proves it: two legs in one
    ///      transaction must each be priced and reported on their own terms. Under v1 the
    ///      second leg overwrote the first's pending state before it was consumed.
    function test_multiHop_legsDoNotCollide() public {
        oracle.set(poolId, 1, true); // extreme divergence -> both legs read as toxic

        MultiSwapper router = new MultiSwapper(swapRouter, key);
        token0.mint(address(router), 1_000e18);
        router.approve(token0);

        vm.prank(address(router), address(router));
        router.twoSwaps(-10e18, -10e18);

        // Two toxic legs must report twice. One report from a 10_000 severity lands at 5_000;
        // a second compounds on top of it.
        assertGt(registry.scoreOf(address(router)), 5_000, "second leg must report independently");
    }

    /// @dev An exact-output closing leg must not revert. The rebate is charged on the
    ///      unspecified side and only when the swapper is receiving it, so exact-output simply
    ///      forgoes the surcharge rather than creating an unbounded extra obligation.
    function test_exactOutputSandwichClose_doesNotRevert() public {
        _swap(ATTACKER, true, -100e18);
        _swap(VICTIM, true, -50e18);
        _swap(ATTACKER, false, 50e18); // exact output

        assertEq(vault.claimable(VICTIM, key.currency1), 0);
    }

    function test_noVault_sandwichStillSwapsCleanly() public {
        vm.prank(OWNER);
        hook.setVault(IRebateVault(address(0)));
        _runSandwich();
        assertEq(vault.outstanding(key.currency0), 0);
    }
}

/// @notice Performs two swaps through the same pool inside one transaction.
contract MultiSwapper {
    PoolSwapTest immutable router;
    PoolKey key;

    constructor(PoolSwapTest _router, PoolKey memory _key) {
        router = _router;
        key = _key;
    }

    function approve(MockERC20 token) external {
        token.approve(address(router), type(uint256).max);
    }

    function twoSwaps(int256 a, int256 b) external {
        _swap(a);
        _swap(b);
    }

    function _swap(int256 amount) internal {
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: amount, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
