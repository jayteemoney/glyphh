// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {GlyphHook} from "../src/GlyphHook.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {GlyphCallbackAdapter} from "../src/reactive/GlyphCallbackAdapter.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @notice LocalDemo — the whole Glyph stack in one broadcast, for `anvil` demos and CI.
///
/// Unlike the testnet `DeployGlyph` (which targets a live PoolManager/Pyth), this script
/// deploys *everything* — PoolManager, two mock tokens, registry, hook, adapter, the v4 test
/// routers, liquidity, and bot funding — so `forge script LocalDemo --broadcast` against a
/// fresh anvil yields a pool the demo bots can immediately trade.
///
/// IMPORTANT — CREATE2 mining: inside a forge broadcast, `new GlyphHook{salt}` is deployed by
/// the deterministic CREATE2 factory (0x4e59...4956C), NOT the EOA. So the hook salt MUST be
/// mined against that factory address, or the address won't carry the permission flags.
///
/// Run:
///   anvil &
///   forge script script/LocalDemo.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --private-key 0xac09...ff80 --broadcast
contract LocalDemo is Script {
    // Foundry's deterministic CREATE2 deployer — the actual deployer of `new{salt}` in scripts.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Default anvil accounts #1 and #2 — the attacker and clean bot wallets.
    address constant DEFAULT_ATTACKER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant DEFAULT_CLEAN = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address attacker = vm.envOr("ATTACKER_ADDRESS", DEFAULT_ATTACKER);
        address clean = vm.envOr("CLEAN_ADDRESS", DEFAULT_CLEAN);

        vm.startBroadcast(deployerKey);

        // 1. Core infra
        PoolManager manager = new PoolManager(deployer);
        MockERC20 tA = new MockERC20("Glyph A", "GA", 18);
        MockERC20 tB = new MockERC20("Glyph B", "GB", 18);
        (MockERC20 token0, MockERC20 token1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        ReputationRegistry registry = new ReputationRegistry(deployer);

        // 2. Mine the hook salt against the CREATE2 factory (the real deployer in scripts).
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(address(manager), address(registry), address(0), deployer);
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(GlyphHook).creationCode, args);

        GlyphHook hook = new GlyphHook{salt: salt}(
            IPoolManager(address(manager)),
            IReputationRegistry(address(registry)),
            IPyth(address(0)), // no Pyth locally — impact path returns 0, fees driven by reputation
            deployer
        );
        require(address(hook) == expected, "hook address mismatch");

        // 3. Wire registry: authorize the hook + a local attestor (the deployer).
        registry.setHook(address(hook), true);
        registry.setAttestor(deployer, true);

        GlyphCallbackAdapter adapter = new GlyphCallbackAdapter(address(0), IReputationRegistry(address(registry)));
        registry.setReactiveProxy(address(adapter));

        // 4. Test routers (swaps + LP).
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        // 5. Initialize the dynamic-fee pool and seed wide-range liquidity.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        uint256 liq = 100_000e18;
        token0.mint(deployer, liq);
        token1.mint(deployer, liq);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: int256(liq), salt: bytes32(0)}),
            ""
        );

        // 6. Fund the two bot wallets so they can trade.
        token0.mint(attacker, 1_000e18);
        token1.mint(attacker, 1_000e18);
        token0.mint(clean, 1_000e18);
        token1.mint(clean, 1_000e18);

        vm.stopBroadcast();

        // 7. Emit a ready-to-paste config block.
        console2.log("==== Glyph local demo deployed ====");
        console2.log("PoolManager:         ", address(manager));
        console2.log("ReputationRegistry:  ", address(registry));
        console2.log("GlyphHook:           ", address(hook));
        console2.log("GlyphCallbackAdapter:", address(adapter));
        console2.log("PoolSwapTest(router):", address(swapRouter));
        console2.log("token0:              ", address(token0));
        console2.log("token1:              ", address(token1));
        console2.log("-- demo/.env --");
        console2.log("REGISTRY_ADDRESS=", address(registry));
        console2.log("HOOK_ADDRESS=", address(hook));
        console2.log("SWAP_ROUTER_ADDRESS=", address(swapRouter));
        console2.log("CURRENCY0=", address(token0));
        console2.log("CURRENCY1=", address(token1));
    }
}
