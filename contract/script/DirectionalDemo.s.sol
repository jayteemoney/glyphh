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

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

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
///
///         **The reference is derived from the live pool price, not hardcoded.** An earlier
///         version set it to a flat 0.99e18, which produced exactly 101 bps only while the pool
///         happened to sit at parity. Every swap moves the pool, so by the second demo run the
///         divergence — and therefore the fee quoted on camera — would have drifted off the
///         number the script, the README and the deck all promise. Solving for the reference
///         instead makes the pair reproducible on a pool in any state.
///
///         Run `DemoPrep.s.sol` first when recording: it does the mint/approve/reset work so
///         this script is three transactions rather than seven.
contract DirectionalDemo is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev 101 bps: comfortably clear of the 40 bp tolerance, and the number the README,
    ///      docs/DEPLOYMENT.md and the deck all quote. 101 - 40 = 61, at 60% capture = 3660.
    uint256 constant TARGET_BPS = 101;

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

        if (vm.envOr("DEMO_SKIP_PREP", false) == false) {
            address me = vm.addr(key);
            MockERC20(t0).mint(me, amount * 10);
            MockERC20(t1).mint(me, amount * 10);
            MockERC20(t0).approve(router, type(uint256).max);
            MockERC20(t1).approve(router, type(uint256).max);
        }

        // Solve for the reference that puts the pool exactly TARGET_BPS above it, from the
        // pool's live price. divergence = (pool - ref) / ref, so ref = pool * 10_000 / 10_101.
        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManager).getSlot0(id);
        require(sqrtPriceX96 != 0, "pool not initialized");
        uint256 poolPrice = _poolPrice(sqrtPriceX96);
        uint256 refPrice = FullMath.mulDiv(poolPrice, 10_000, 10_000 + TARGET_BPS);

        SettablePriceOracle(oracle).setPrice(id, refPrice, true);
        console2.log("pool price :", poolPrice);
        console2.log("reference  :", refPrice);
        console2.log("Pool sits ~101 bps above the reference, so zeroForOne closes the gap.");

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Recording the demo works far better as two separate commands than one: each is a
        // single transaction, so each lands in seconds and gives its own reveal, instead of one
        // long silence covering both. DEMO_DIRECTION picks which.
        string memory dir = vm.envOr("DEMO_DIRECTION", string("both"));
        bool doClosing = _eq(dir, "both") || _eq(dir, "closing");
        bool doWidening = _eq(dir, "both") || _eq(dir, "widening");

        // 1. Gap-closing: sells token0 into the pool, pushing its price down toward the reference.
        if (doClosing)
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
        if (doClosing) console2.log("gap-closing swap sent (expect base 3000 + arb 3660 = 0.666%).");

        // 2. Gap-widening: the same size back the other way, pushing the price further above.
        if (doWidening)
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
        if (doWidening) console2.log("gap-widening swap sent (expect arb 0, final 0.300%).");

        vm.stopBroadcast();
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Mirrors GlyphHook._poolPrice exactly, so the reference we solve for is measured on
    ///      the same scale the hook compares it against.
    function _poolPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(priceX96, 1e18, 1 << 96);
    }

}
