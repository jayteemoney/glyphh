// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {GlyphHook} from "../src/GlyphHook.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {SandwichBundler} from "./SandwichBundler.sol";

/// @notice Stage a sandwich against the live deployment and show the victim being paid.
///
/// @dev    Why this is bundled into one transaction rather than three.
///
///         A sandwich in the wild is three transactions landing in one block. Reproducing that
///         against a public testnet RPC turned out to be unreliable for two independent
///         reasons: on Unichain's one-second blocks the legs landed two blocks apart, and the
///         load-balanced RPC served a stale nonce that rejected the closing leg outright.
///
///         The detection path does not care. `_trackBlock` matches on per-pool *block* state,
///         so three legs in one transaction and three legs in three transactions traverse
///         identical code. What the bundle buys is determinism: the legs are guaranteed
///         adjacent and correctly ordered, which is what a demo needs.
///
///         The three legs carry three distinct identities through `hookData`, resolved by the
///         hook's tier-1 trusted-router path -- the same mechanism a production router uses to
///         let its users carry their own reputation. Nothing here is a special case in the
///         hook; the demo simply uses a feature that already exists.
contract SandwichDemo is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        GlyphHook hook = GlyphHook(vm.envAddress("HOOK_ADDRESS"));
        RebateVault vault = RebateVault(payable(vm.envAddress("VAULT_ADDRESS")));
        PoolSwapTest router = PoolSwapTest(vm.envAddress("SWAP_ROUTER_ADDRESS"));
        address token0 = vm.envAddress("CURRENCY0");
        address token1 = vm.envAddress("CURRENCY1");
        address attacker = vm.envAddress("ATTACKER_ADDRESS");
        address victim = vm.envAddress("CLEAN_ADDRESS");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        console2.log("Attacker:", attacker);
        console2.log("Victim:  ", victim);
        console2.log("Vault owes victim before:", vault.claimable(victim, key.currency0));

        vm.startBroadcast(deployerKey);

        SandwichBundler bundler = new SandwichBundler(router);

        // Tier-1 identity: the router is trusted to name the real swapper in hookData, so the
        // three legs are three distinct identities rather than one bundler address.
        hook.setTrustedRouter(address(router), true);

        MockERC20(token0).mint(address(bundler), 500e18);
        MockERC20(token1).mint(address(bundler), 500e18);
        bundler.approve(token0);
        bundler.approve(token1);

        bundler.runSandwich(key, attacker, victim, 50e18, 30e18);

        vm.stopBroadcast();

        uint256 owed = vault.claimable(victim, key.currency0);
        console2.log("Vault owes victim after: ", owed);
        console2.log("Attacker toxicity score: ", uint256(hook.registry().scoreOf(attacker)));
        require(owed > 0, "no rebate credited - sandwich not detected");
        console2.log("Sandwich detected; victim credited.");
    }
}
