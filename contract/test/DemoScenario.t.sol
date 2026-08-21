// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {GlyphHook} from "../src/GlyphHook.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";
import {IGlyphRegistry} from "../src/interfaces/IGlyphRegistry.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice DemoScenario — the end-to-end "toxic vs clean" narrative the demo bots act out,
/// asserted deterministically. Crucially it sets BOTH msg.sender and tx.origin (the 2-arg
/// `vm.startPrank`), because the hook keys fees/scores on `tx.origin`. The pre-existing
/// GlyphHook tests pranked only msg.sender, so a high-score swap silently fell back to the
/// base fee and never exercised the post-swap premium path — which is where the unfunded
/// `donate()` reverted live with CurrencyNotSettled. This suite would have caught that.
contract DemoScenarioTest is Test {
    using StateLibrary for PoolManager;

    using PoolIdLibrary for PoolKey;

    address constant OWNER = address(0xD1);
    uint256 constant ATTESTOR_PK = 0xA11CE;

    // Real EOAs whose tx.origin the hook will see.
    address toxic = address(0xBADBEEF);
    address clean = address(0xC1EA11);

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    ReputationRegistry registry;
    GlyphHook hook;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;

    event LPDonation(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    function setUp() public {
        manager = new PoolManager(OWNER);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        registry = new ReputationRegistry(OWNER);

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(address(manager), address(registry), address(0), OWNER);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(GlyphHook).creationCode, args);
        hook = new GlyphHook{salt: salt}(
            IPoolManager(address(manager)), IGlyphRegistry(address(registry)), IPriceOracle(address(0)), OWNER
        );

        vm.startPrank(OWNER);
        registry.setHook(address(hook), true);
        registry.setAttestor(vm.addr(ATTESTOR_PK), true);
        vm.stopPrank();

        MockERC20 tA = new MockERC20("A", "A", 18);
        MockERC20 tB = new MockERC20("B", "B", 18);
        (token0, token1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000e18, salt: bytes32(0)}),
            ""
        );

        for (uint256 i; i < 2; i++) {
            address t = i == 0 ? toxic : clean;
            token0.mint(t, 1_000e18);
            token1.mint(t, 1_000e18);
            vm.startPrank(t);
            token0.approve(address(swapRouter), type(uint256).max);
            token1.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev v1 asserted on an `LPDonation` event, which was only observability — the premium
    ///      is actually paid through v4's dynamic fee override, and the event merely announced
    ///      it. v2 asserts the thing that matters directly: a toxic swap grows the pool's LP
    ///      fee accumulator by more than an identical clean swap does. That is the "toxic flow
    ///      pays LPs" claim, measured rather than announced.
    function test_toxicSwap_growsLPFeesMoreThanCleanSwap() public {
        (uint256 cleanBefore,) = manager.getFeeGrowthGlobals(key.toId());
        _swap(clean);
        (uint256 cleanAfter,) = manager.getFeeGrowthGlobals(key.toId());
        uint256 cleanGrowth = cleanAfter - cleanBefore;

        _scoreToxic(8_000);

        (uint256 toxicBefore,) = manager.getFeeGrowthGlobals(key.toId());
        _swap(toxic);
        (uint256 toxicAfter,) = manager.getFeeGrowthGlobals(key.toId());
        uint256 toxicGrowth = toxicAfter - toxicBefore;

        assertGt(cleanGrowth, 0, "clean swap should still pay the base fee to LPs");
        assertGt(toxicGrowth, cleanGrowth, "toxic flow must pay LPs more than clean flow");
    }

    /// A clean wallet pays the base fee and accrues no toxicity.
    function test_cleanSwap_paysBaseFeeAndStaysClean() public {
        _swap(clean);
        assertEq(registry.scoreOf(clean), 0);
    }

    function _swap(address who) internal {
        // 2-arg prank: sets msg.sender AND tx.origin, so the hook resolves the intended wallet.
        vm.prank(who, who);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _scoreToxic(uint16 score) internal {
        IReputationRegistry.Score memory sd = registry.scoreDataOf(toxic);
        uint32 nonce = sd.nonce + 1;
        uint64 deadline = uint64(block.timestamp + 600);
        bytes32 structHash = keccak256(abi.encode(registry.SCORE_TYPEHASH(), toxic, score, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, digest);

        registry.updateScore(
            IReputationRegistry.Attestation({
                wallet: toxic,
                value: score,
                nonce: nonce,
                deadline: deadline,
                signature: abi.encodePacked(r, s, v)
            })
        );
    }
}
