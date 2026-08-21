// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

import {GlyphHook} from "../src/GlyphHook.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {GlyphCallbackAdapter} from "../src/reactive/GlyphCallbackAdapter.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";
import {IGlyphRegistry} from "../src/interfaces/IGlyphRegistry.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {PythPriceOracle} from "../src/oracles/PythPriceOracle.sol";
import {SettablePriceOracle} from "../src/oracles/SettablePriceOracle.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

contract DeployGlyph is Script {
    using PoolIdLibrary for PoolKey;

    // v2 adds AFTER_SWAP_RETURNS_DELTA for the sandwich-rebate path. Permissions live in the
    // hook's address, so this flag set must match GlyphHook.getHookPermissions() exactly or
    // the constructor's validateHookPermissions reverts the deployment.
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    address constant UNICHAIN_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant UNICHAIN_PYTH         = 0x2880aB155794e7179c9eE2e38200202908C17B43;

    // Foundry's deterministic CREATE2 deployer. Inside a broadcast, `new GlyphHook{salt}` is
    // deployed BY this factory, not by the EOA — so the hook salt must be mined against it or
    // the resulting address won't carry the permission flags (the `require` below would fail).
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

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

        // Two oracles, both implementing IPriceOracle, and the hook cannot tell them apart.
        // That is the point of the adapter seam.
        //
        // PythPriceOracle is the production adapter: real feeds, staleness and confidence
        // gates, deployed and verified so it can be inspected.
        //
        // The demo pool, however, is a pair of *mock* tokens with no Pyth feed. Pointing it at
        // the real ETH/USD and USDC/USD feeds would put the reference price near 4000 against a
        // pool initialised at 1.0 -- divergence would saturate and every gap-closing swap would
        // read as maximally toxic. That is precisely the v1 failure this rebuild exists to fix,
        // and shipping it again in a new costume would be worse than not shipping L1 at all.
        // So the demo pool gets a settable reference price, seeded to the pool's own opening
        // price, which also lets the demo move it on camera.
        PythPriceOracle pythOracle = new PythPriceOracle(IPyth(pythAddress), deployer);
        console2.log("PythPriceOracle:   ", address(pythOracle));

        SettablePriceOracle oracle = new SettablePriceOracle(deployer);
        console2.log("SettablePriceOracle:", address(oracle));

        RebateVault vault = new RebateVault(deployer);
        console2.log("RebateVault:       ", address(vault));

        (address expectedHookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HOOK_FLAGS,
            type(GlyphHook).creationCode,
            abi.encode(poolManager, address(registry), address(oracle), deployer)
        );

        GlyphHook hook = new GlyphHook{salt: salt}(
            IPoolManager(poolManager),
            IGlyphRegistry(address(registry)),
            IPriceOracle(address(oracle)),
            deployer
        );
        require(address(hook) == expectedHookAddr, "hook address mismatch");
        console2.log("GlyphHook:         ", address(hook));

        registry.setHook(address(hook), true);
        registry.setAttestor(attestorAddr, true);

        // Without this the sandwich surcharge has nowhere to go and _payRebate returns 0.
        vault.setHook(address(hook), true);
        hook.setVault(IRebateVault(address(vault)));
        console2.log("Hook authorized, attestor authorized, vault wired.");

        // Reactive path (P2): deploy the destination-chain callback adapter and register it
        // as the registry's reactiveProxy. The GlyphReactive RSC itself deploys separately on
        // the Reactive Network (Kopli) — see script/DeployReactive.s.sol.
        address callbackProxy = vm.envOr("CALLBACK_PROXY_ADDRESS", address(0));
        GlyphCallbackAdapter adapter = new GlyphCallbackAdapter(callbackProxy, IReputationRegistry(address(registry)));
        registry.setReactiveProxy(address(adapter));
        console2.log("GlyphCallbackAdapter:", address(adapter));

        address tokenA = vm.envOr("TOKEN_A", address(0));
        address tokenB = vm.envOr("TOKEN_B", address(0));

        if (tokenA != address(0) && tokenB != address(0)) {
            _initPool(IPoolManager(poolManager), hook, oracle, pythOracle, tokenA, tokenB);
        } else {
            console2.log("TOKEN_A/TOKEN_B not set - run DeployMockTokens.s.sol first.");
        }

        vm.stopBroadcast();

        console2.log("---");
        console2.log("Copy these into your .env:");
        console2.log("REGISTRY_ADDRESS=", address(registry));
        console2.log("HOOK_ADDRESS=    ", address(hook));
        console2.log("CALLBACK_ADAPTER=", address(adapter));
        console2.log("ORACLE_ADDRESS=  ", address(oracle));
        console2.log("VAULT_ADDRESS=   ", address(vault));
    }

    function _initPool(
        IPoolManager pm,
        GlyphHook hook,
        SettablePriceOracle oracle,
        PythPriceOracle pythOracle,
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

        // Seed the demo pool's reference at its opening price (tick 0 -> 1e18), so the pool
        // starts *at* the oracle and L1 charges nothing until the price is deliberately moved.
        oracle.setPrice(k.toId(), 1e18, true);
        console2.log("Reference price seeded at parity; L1 quiet until moved.");

        // The production adapter is configured too, on the same pool id, so the real feed path
        // is deployed and inspectable even though the demo pool does not price against it.
        pythOracle.setFeeds(k.toId(), ETH_USD_FEED, USDC_USD_FEED);
        console2.log("Pyth feeds configured on the production adapter.");
    }
}
