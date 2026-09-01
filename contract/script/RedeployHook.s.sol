// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {GlyphHook} from "../src/GlyphHook.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {SettablePriceOracle} from "../src/oracles/SettablePriceOracle.sol";
import {RebateVault} from "../src/RebateVault.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {IGlyphRegistry} from "../src/interfaces/IGlyphRegistry.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IRebateVault} from "../src/interfaces/IRebateVault.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @notice Redeploy *only* the hook, onto the existing registry, vault, oracles and routers.
///
/// @dev    Written for the tolerance retune: `ai/backtest/lvr.py` showed ARB_TOLERANCE_BPS was
///         set inside the pool's no-arbitrage band, so it surcharged uninformed flow instead of
///         arbitrage. Fixing a constant in a library that is inlined into the hook changes the
///         hook's bytecode and therefore its mined address, so the hook must be redeployed and
///         a fresh pool initialised behind it.
///
///         Everything else is deliberately reused. The registry keeps its accumulated scores,
///         the vault keeps its accounting, and the routers are pool-agnostic — so this is a few
///         hundred thousand gas rather than a full restack, and the addresses judges have
///         already been given for those contracts stay valid.
contract RedeployHook is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address poolManager = vm.envAddress("POOL_MANAGER");
        address registryAddr = vm.envAddress("REGISTRY_ADDRESS");
        address oracleAddr = vm.envAddress("ORACLE_ADDRESS");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address lpRouter = vm.envAddress("LP_ROUTER_ADDRESS");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint256 liquidity = vm.envOr("LIQUIDITY", uint256(100_000e18));

        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        console2.log("Reusing registry:", registryAddr);
        console2.log("Reusing oracle:  ", oracleAddr);
        console2.log("Reusing vault:   ", vaultAddr);
        console2.log("---");

        vm.startBroadcast(deployerKey);

        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HOOK_FLAGS,
            type(GlyphHook).creationCode,
            abi.encode(poolManager, registryAddr, oracleAddr, deployer)
        );

        GlyphHook hook = new GlyphHook{salt: salt}(
            IPoolManager(poolManager),
            IGlyphRegistry(registryAddr),
            IPriceOracle(oracleAddr),
            deployer
        );
        require(address(hook) == expected, "hook address mismatch");
        console2.log("GlyphHook (new): ", address(hook));

        ReputationRegistry(registryAddr).setHook(address(hook), true);
        RebateVault(payable(vaultAddr)).setHook(address(hook), true);
        hook.setVault(IRebateVault(vaultAddr));
        console2.log("Authorized on registry and vault; vault wired.");

        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId id = k.toId();

        // Check first rather than wrapping initialize in try/catch: a try/catch is idempotent in
        // simulation but forge still records the call for broadcast, where it reverts.
        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManager).getSlot0(id);
        if (sqrtPriceX96 == 0) {
            IPoolManager(poolManager).initialize(k, TickMath.getSqrtPriceAtTick(0));
            console2.log("Pool initialized.");
        } else {
            console2.log("Pool already initialized.");
        }

        SettablePriceOracle(oracleAddr).setPrice(id, 1e18, true);
        console2.log("Reference seeded at parity.");

        MockERC20(t0).mint(deployer, liquidity);
        MockERC20(t1).mint(deployer, liquidity);
        MockERC20(t0).approve(lpRouter, type(uint256).max);
        MockERC20(t1).approve(lpRouter, type(uint256).max);

        // +/- 60_000 ticks: a narrow band lets a demo swap push the price past the range and
        // revert with PriceLimitAlreadyExceeded.
        PoolModifyLiquidityTest(lpRouter).modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: -60_000,
                tickUpper: 60_000,
                liquidityDelta: int256(liquidity),
                salt: bytes32(0)
            }),
            ""
        );
        console2.log("Liquidity seeded.");

        vm.stopBroadcast();

        console2.log("---");
        console2.log("HOOK_ADDRESS=", address(hook));
        console2.log("POOL_ID=");
        console2.logBytes32(PoolId.unwrap(id));
    }
}
