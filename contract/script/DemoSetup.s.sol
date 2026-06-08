// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {MockERC20} from "../src/MockERC20.sol";

/// @notice DemoSetup — the P0 glue that turns a freshly-deployed Glyph pool into a *swappable*
/// pool the demo bots (demo/attacker_bot.ts, demo/clean_trader.ts) can trade against.
///
/// `DeployGlyph` deploys the registry/hook/adapter and *initializes* the pool, but adds no
/// liquidity and no router. This script:
///   1. Deploys the v4 test routers (PoolSwapTest = swaps, PoolModifyLiquidityTest = LP).
///   2. Initializes the pool if it isn't already (idempotent).
///   3. Seeds a wide liquidity position so swaps don't move price into a revert.
///   4. Mints the two mock tokens to the attacker + clean bot wallets so they can trade.
///
/// Run (after DeployGlyph + DeployMockTokens):
///   DEPLOYER_PRIVATE_KEY=0x... TOKEN_A=0x... TOKEN_B=0x... HOOK_ADDRESS=0x... \
///   ATTACKER_ADDRESS=0x... CLEAN_ADDRESS=0x... \
///   forge script script/DemoSetup.s.sol --rpc-url "$RPC_URL" --broadcast
contract DemoSetup is Script {
    using PoolIdLibrary for PoolKey;

    address constant UNICHAIN_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address poolManager = vm.envOr("POOL_MANAGER", UNICHAIN_POOL_MANAGER);
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        // Liquidity sizing: a wide band keeps small demo swaps far from the edges.
        uint256 liquidity = vm.envOr("LIQUIDITY", uint256(100_000e18));
        uint256 botFunding = vm.envOr("BOT_FUNDING", uint256(1_000e18));

        // Optional bot wallets to fund; default to the deployer if unset.
        address attacker = vm.envOr("ATTACKER_ADDRESS", deployer);
        address clean = vm.envOr("CLEAN_ADDRESS", deployer);

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hookAddr)
        });

        console2.log("Deployer:   ", deployer);
        console2.log("PoolManager:", poolManager);
        console2.log("Hook:       ", hookAddr);
        console2.log("token0:     ", token0);
        console2.log("token1:     ", token1);
        console2.log("---");

        vm.startBroadcast(deployerKey);

        // 1. Routers — the bots route swaps through PoolSwapTest.
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(poolManager));
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(poolManager));
        console2.log("PoolSwapTest (SWAP_ROUTER):", address(swapRouter));
        console2.log("PoolModifyLiquidityTest:   ", address(lpRouter));

        // 2. Initialize the pool if DeployGlyph didn't already (idempotent).
        try IPoolManager(poolManager).initialize(key, TickMath.getSqrtPriceAtTick(0)) {
            console2.log("Pool initialized at tick 0.");
        } catch {
            console2.log("Pool already initialized - continuing.");
        }

        // 3. Mint + approve, then seed a wide-range liquidity position.
        MockERC20(token0).mint(deployer, liquidity);
        MockERC20(token1).mint(deployer, liquidity);
        MockERC20(token0).approve(address(lpRouter), type(uint256).max);
        MockERC20(token1).approve(address(lpRouter), type(uint256).max);

        int24 tickLower = (-6_000 / tickSpacing) * tickSpacing;
        int24 tickUpper = (6_000 / tickSpacing) * tickSpacing;
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(liquidity),
                salt: bytes32(0)
            }),
            ""
        );
        console2.log("Liquidity added. tickLower:", int256(tickLower));
        console2.log("                 tickUpper:", int256(tickUpper));

        // 4. Fund the bot wallets so they hold both currencies. (The bots approve the
        //    router themselves from their own keys via ensureApprovals.)
        if (attacker != deployer) {
            MockERC20(token0).mint(attacker, botFunding);
            MockERC20(token1).mint(attacker, botFunding);
            console2.log("Funded attacker:", attacker);
        }
        if (clean != deployer && clean != attacker) {
            MockERC20(token0).mint(clean, botFunding);
            MockERC20(token1).mint(clean, botFunding);
            console2.log("Funded clean:   ", clean);
        }

        vm.stopBroadcast();

        console2.log("---");
        console2.log("Copy into demo/.env:");
        console2.log("SWAP_ROUTER_ADDRESS=", address(swapRouter));
        console2.log("CURRENCY0=", token0);
        console2.log("CURRENCY1=", token1);
    }
}
