// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

import {GlyphHook} from "../src/GlyphHook.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {GlyphReactive} from "../src/reactive/GlyphReactive.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

contract DeployGlyph is Script {
    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    address constant UNICHAIN_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant UNICHAIN_PYTH         = 0x2880aB155794e7179c9eE2e38200202908C17B43;

    bytes32 constant ETH_USD_FEED  = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant USDC_USD_FEED = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    function run() external {
        uint256 deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer     = vm.addr(deployerKey);
        address poolManager  = vm.envOr("POOL_MANAGER",    UNICHAIN_POOL_MANAGER);
        address pythAddress  = vm.envOr("PYTH_ADDRESS",    UNICHAIN_PYTH);
        address attestorAddr = vm.envOr("ATTESTOR_ADDRESS", deployer);

        console2.log("Deployer:      ", deployer);
        console2.log("PoolManager:   ", poolManager);
        console2.log("Pyth:          ", pythAddress);
        console2.log("Attestor:      ", attestorAddr);
        console2.log("---");

        vm.startBroadcast(deployerKey);

        ReputationRegistry registry = new ReputationRegistry(deployer);
        console2.log("ReputationRegistry:", address(registry));

        (address expectedHookAddr, bytes32 salt) = HookMiner.find(
            deployer,
            HOOK_FLAGS,
            type(GlyphHook).creationCode,
            abi.encode(poolManager, address(registry), pythAddress, deployer)
        );

        GlyphHook hook = new GlyphHook{salt: salt}(
            IPoolManager(poolManager),
            IReputationRegistry(address(registry)),
            IPyth(pythAddress),
            deployer
        );
        require(address(hook) == expectedHookAddr, "hook address mismatch");
        console2.log("GlyphHook:         ", address(hook));

        registry.setHook(address(hook), true);
        registry.setAttestor(attestorAddr, true);
        console2.log("Hook authorized, attestor authorized.");

        GlyphReactive reactive = new GlyphReactive(address(registry));
        registry.setReactiveProxy(address(reactive));
        console2.log("GlyphReactive:     ", address(reactive));

        address tokenA = vm.envOr("TOKEN_A", address(0));
        address tokenB = vm.envOr("TOKEN_B", address(0));

        if (tokenA != address(0) && tokenB != address(0)) {
            _initPool(IPoolManager(poolManager), hook, tokenA, tokenB);
        } else {
            console2.log("TOKEN_A/TOKEN_B not set — run DeployMockTokens.s.sol first.");
        }

        vm.stopBroadcast();

        console2.log("---");
        console2.log("Copy these into your .env:");
        console2.log("REGISTRY_ADDRESS=", address(registry));
        console2.log("HOOK_ADDRESS=    ", address(hook));
        console2.log("REACTIVE_ADDRESS=", address(reactive));
    }

    function _initPool(
        IPoolManager pm,
        GlyphHook hook,
        address tokenA,
        address tokenB
    ) internal {
        (address t0, address t1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        pm.initialize(k, TickMath.getSqrtPriceAtTick(0));
        console2.log("Pool initialized: token0=", t0, "token1=", t1);

        hook.setFeedConfig(k, ETH_USD_FEED, USDC_USD_FEED);
        console2.log("Pyth feeds configured.");
    }
}
