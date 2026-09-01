// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {SettablePriceOracle} from "../src/oracles/SettablePriceOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Prove the cross-pool claim end to end: one wallet, two distinct pools, one callback.
///
/// @dev    `GlyphReactive` propagates a wallet only once it has been reported toxic in
///         **MIN_DISTINCT_POOLS = 2** different pools. Until now the live deployment had exactly
///         one Glyph pool, so that path had been exercised from both sides of its authorization
///         boundary but had never actually fired — the one claim in the README without a
///         transaction behind it.
///
///         This script stands up a second pool behind the *same* hook (same tokens, same
///         registry, different tickSpacing, therefore a different PoolId), pushes the reference
///         price far enough from both pools to clear `TOXIC_DIVERGENCE_BPS`, and has one wallet
///         make a gap-closing swap in each. Two `ToxicSwapReported` events with two different
///         pool ids is exactly the input the RSC's distinct-pool set is counting.
contract CrossPoolDemo is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Pool B differs from pool A only in tickSpacing. That is the cheapest way to obtain a
    ///      genuinely different PoolId behind the same hook — no new tokens, no new oracle, no
    ///      new registry entry, so the thing under test is the distinct-pool logic and nothing else.
    int24 constant SPACING_B = 30;
    int24 constant SPACING_A = 60;

    /// @dev 0.97e18 against a pool near parity is ~309 bps, comfortably over the hook's 200 bp
    ///      toxicity threshold and over the 40 bp arbitrage tolerance.
    uint256 constant REFERENCE = 0.97e18;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 attackerKey = vm.envUint("ATTACKER_PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("HOOK_ADDRESS");
        address oracleAddr = vm.envAddress("ORACLE_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address lpRouter = vm.envAddress("LP_ROUTER_ADDRESS");
        address t0 = vm.envAddress("CURRENCY0");
        address t1 = vm.envAddress("CURRENCY1");
        address attacker = vm.addr(attackerKey);
        uint256 liquidity = vm.envOr("LIQUIDITY", uint256(100_000e18));
        uint256 amount = vm.envOr("DEMO_SWAP_AMOUNT", uint256(1e18));

        PoolKey memory a = _key(t0, t1, hook, SPACING_A);
        PoolKey memory b = _key(t0, t1, hook, SPACING_B);

        console2.log("pool A id:");
        console2.logBytes32(PoolId.unwrap(a.toId()));
        console2.log("pool B id:");
        console2.logBytes32(PoolId.unwrap(b.toId()));
        console2.log("attacker:", attacker);

        // ── deployer: stand up pool B, and point the reference away from both pools ──
        vm.startBroadcast(deployerKey);

        (uint160 sqrtB,,,) = IPoolManager(poolManager).getSlot0(b.toId());
        if (sqrtB == 0) {
            IPoolManager(poolManager).initialize(b, TickMath.getSqrtPriceAtTick(0));
            console2.log("pool B initialized");

            MockERC20(t0).mint(vm.addr(deployerKey), liquidity);
            MockERC20(t1).mint(vm.addr(deployerKey), liquidity);
            MockERC20(t0).approve(lpRouter, type(uint256).max);
            MockERC20(t1).approve(lpRouter, type(uint256).max);

            PoolModifyLiquidityTest(lpRouter).modifyLiquidity(
                b,
                ModifyLiquidityParams({
                    tickLower: -60_000,
                    tickUpper: 60_000,
                    liquidityDelta: int256(liquidity),
                    salt: bytes32(0)
                }),
                ""
            );
            console2.log("pool B liquidity seeded");
        } else {
            console2.log("pool B already initialized");
        }

        SettablePriceOracle(oracleAddr).setPrice(a.toId(), REFERENCE, true);
        SettablePriceOracle(oracleAddr).setPrice(b.toId(), REFERENCE, true);
        console2.log("reference set to 0.97e18 on both pools (~309 bps divergence)");

        // The attacker needs something to sell and gas to sell it with.
        MockERC20(t0).mint(attacker, amount * 20);
        (bool ok,) = attacker.call{value: 0.0015 ether}("");
        require(ok, "gas top-up failed");

        vm.stopBroadcast();

        // ── attacker: one gap-closing swap in each pool ──
        // tx.origin is the attacker here, which is what the hook's tier-3 identity path reads.
        vm.startBroadcast(attackerKey);

        MockERC20(t0).approve(swapRouter, type(uint256).max);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory closing = SwapParams({
            zeroForOne: true, // pool sits above the reference, so selling token0 closes the gap
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest(swapRouter).swap(a, closing, settings, "");
        console2.log("1/2 toxic swap in pool A -> ToxicSwapReported(attacker, poolA, ...)");

        PoolSwapTest(swapRouter).swap(b, closing, settings, "");
        console2.log("2/2 toxic swap in pool B -> ToxicSwapReported(attacker, poolB, ...)");

        vm.stopBroadcast();

        console2.log("---");
        console2.log("Two distinct pools reported. GlyphReactive should now dispatch:");
        console2.log("  CrossPoolDispatch -> callback proxy -> GlyphCallbackAdapter");
        console2.log("  -> ReputationRegistry.updateScoreFromReactive");
    }

    function _key(address t0, address t1, address hook, int24 spacing) internal pure returns (PoolKey memory) {
        (address c0, address c1) = t0 < t1 ? (t0, t1) : (t1, t0);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(hook)
        });
    }
}
