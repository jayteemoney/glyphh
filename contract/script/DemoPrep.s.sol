// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {SettablePriceOracle} from "../src/oracles/SettablePriceOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {GlyphHook} from "../src/GlyphHook.sol";
import {SandwichBundler} from "./SandwichBundler.sol";

/// @notice Everything slow, done before the camera rolls.
///
/// @dev    A demo recorded against a testnet has one enemy: dead air. `DirectionalDemo` on its
///         own is seven transactions, of which five are mints and approvals that prove nothing
///         and cost twenty seconds of silence. This script does those ahead of time and resets
///         the pool's reference to parity, so the on-camera run is three transactions — set the
///         reference, swap one way, swap the other — and the dashboard starts quiet at 0.300%
///         the way the script's opening beat assumes.
///
///         Run it, wait for it to finish, then start recording.
contract DemoPrep is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address hook = vm.envAddress("HOOK_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER_ADDRESS");
        address t0 = vm.envAddress("CURRENCY0");
        address t1 = vm.envAddress("CURRENCY1");
        uint256 amount = vm.envOr("DEMO_SWAP_AMOUNT", uint256(1e18));
        address me = vm.addr(key);

        (address c0, address c1) = t0 < t1 ? (t0, t1) : (t1, t0);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        PoolId id = k.toId();

        vm.startBroadcast(key);

        // Enough for many takes, so a re-record never stops to top up.
        MockERC20(c0).mint(me, amount * 200);
        MockERC20(c1).mint(me, amount * 200);
        MockERC20(c0).approve(swapRouter, type(uint256).max);
        MockERC20(c1).approve(swapRouter, type(uint256).max);
        console2.log("minted and approved for ~200 demo swaps");

        // Park the reference exactly on the pool price so L1 is silent. The opening beat shows a
        // quiet dashboard at 0.300%, and it should be quiet because nothing is diverging -- not
        // because the reference happens to be stale.
        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManager).getSlot0(id);
        require(sqrtPriceX96 != 0, "pool not initialized");
        uint256 poolPrice = FullMath.mulDiv(
            FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96), 1e18, 1 << 96
        );
        SettablePriceOracle(oracle).setPrice(id, poolPrice, true);

        // The sandwich beat is seven transactions, of which six are scaffolding: deploy the
        // bundler, authorize it as a trusted router, mint and approve. Only runSandwich is the
        // demo. Deploying and funding it here turns an eighteen-second beat into one send.
        SandwichBundler bundler = new SandwichBundler(PoolSwapTest(swapRouter));
        GlyphHook(hook).setTrustedRouter(address(bundler), true);
        MockERC20(c0).mint(address(bundler), 5_000e18);
        MockERC20(c1).mint(address(bundler), 5_000e18);
        bundler.approve(c0);
        bundler.approve(c1);

        vm.stopBroadcast();

        console2.log("reference parked at the pool price:", poolPrice);
        console2.log("sandwich bundler:", address(bundler));
        console2.log("---");
        console2.log("Add this to contract/.env, then use the shell wrappers on camera:");
        console2.log("  BUNDLER_ADDRESS=", address(bundler));
        console2.log("");
        console2.log("  ./script/demo-reset.sh      opens a 101 bps gap   (~6s)");
        console2.log("  ./script/demo-swap.sh closing                     (~6s)");
        console2.log("  ./script/demo-swap.sh widening                    (~2s)");
        console2.log("  ./script/demo-sandwich.sh                         (~6s)");
    }
}
