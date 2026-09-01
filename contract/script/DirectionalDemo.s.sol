// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SettablePriceOracle} from "../src/oracles/SettablePriceOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice The pair of transactions that carry Glyph's central claim.
///
/// @dev    Two swaps, same pool, same divergence, same size, same wallet, opposite directions.
///         The first closes the gap between the pool and its reference and is charged for the
///         arbitrage it captures; the second widens the gap and pays the base rate. Run as one
///         script so the pair is reproducible rather than a sequence of hand-typed commands.
///
///         Both fees are readable from the hook's own `FeeQuoted` event, term by term.
contract DirectionalDemo is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("HOOK_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address router = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint256 amount = vm.envOr("DEMO_SWAP_AMOUNT", uint256(1e18));

        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        PoolId id = k.toId();

        vm.startBroadcast(key);

        address me = vm.addr(key);
        MockERC20(t0).mint(me, amount * 10);
        MockERC20(t1).mint(me, amount * 10);
        MockERC20(t0).approve(router, type(uint256).max);
        MockERC20(t1).approve(router, type(uint256).max);

        // Put the reference 1% below the pool. The pool opened at 1.0, so a reference of 0.99
        // is 101 bps of divergence: (1.00 - 0.99) / 0.99 = 1.0101%.
        SettablePriceOracle(oracle).setPrice(id, 0.99e18, true);
        console2.log("Reference set to 0.99; pool is above it, so zeroForOne closes the gap.");

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // 1. Gap-closing: sells token0 into the pool, pushing its price down toward 0.99.
        PoolSwapTest(router).swap(
            k,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ""
        );
        console2.log("1/2 gap-closing swap sent (expect base 3000 + arb 3660 = 0.666%).");

        // 2. Gap-widening: the same size back the other way, pushing the price further above.
        PoolSwapTest(router).swap(
            k,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );
        console2.log("2/2 gap-widening swap sent (expect arb 0, final 0.300%).");

        vm.stopBroadcast();
    }
}
