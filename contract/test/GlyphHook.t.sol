// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {GlyphHook} from "../src/GlyphHook.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";
import {ToxicityScoring} from "../src/libraries/ToxicityScoring.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract GlyphHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ── Actors ───────────────────────────────────────────────────────────────

    address constant OWNER        = address(0xD1);
    address constant CLEAN_TRADER = address(0xC1);
    address constant TOXIC_TRADER = address(0xBA);

    // ── Contracts ────────────────────────────────────────────────────────────

    PoolManager              manager;
    PoolSwapTest             swapRouter;
    PoolModifyLiquidityTest  lpRouter;
    ReputationRegistry       registry;
    GlyphHook                hook;
    MockERC20                token0;
    MockERC20                token1;
    PoolKey                  key;

    // ── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        // Deploy core
        manager    = new PoolManager(OWNER);
        swapRouter = new PoolSwapTest(manager);
        lpRouter   = new PoolModifyLiquidityTest(manager);

        // Deploy registry
        registry = new ReputationRegistry(OWNER);

        // Mine a hook address whose low 14 bits match beforeSwap + afterSwap flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory creationCode = type(GlyphHook).creationCode;
        bytes memory args = abi.encode(
            address(manager),
            address(registry),
            address(0), // no Pyth in unit tests
            OWNER
        );
        (, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, args);

        hook = new GlyphHook{salt: salt}(
            IPoolManager(address(manager)),
            IReputationRegistry(address(registry)),
            // IPyth — zero address, Pyth path skips gracefully when feeds unconfigured
            IPyth(address(0)),
            OWNER
        );

        // Authorize hook in registry
        vm.prank(OWNER);
        registry.setHook(address(hook), true);

        // Deploy tokens (sorted so token0 < token1)
        MockERC20 tA = new MockERC20("TokenA", "TA", 18);
        MockERC20 tB = new MockERC20("TokenB", "TB", 18);
        if (address(tA) < address(tB)) {
            token0 = tA; token1 = tB;
        } else {
            token0 = tB; token1 = tA;
        }

        // Initialize pool with dynamic fee flag
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Mint tokens and add liquidity
        uint256 amt = 1_000_000e18;
        token0.mint(address(this), amt);
        token1.mint(address(this), amt);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper:  600,
                liquidityDelta: 100_000e18,
                salt: bytes32(0)
            }),
            ""
        );

        // Fund traders
        token0.mint(CLEAN_TRADER, 100e18);
        token1.mint(CLEAN_TRADER, 100e18);
        token0.mint(TOXIC_TRADER, 100e18);
        token1.mint(TOXIC_TRADER, 100e18);

        vm.prank(CLEAN_TRADER);
        token0.approve(address(swapRouter), type(uint256).max);
        vm.prank(CLEAN_TRADER);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.prank(TOXIC_TRADER);
        token0.approve(address(swapRouter), type(uint256).max);
        vm.prank(TOXIC_TRADER);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    // ── Fee curve ────────────────────────────────────────────────────────────

    function test_scoreZeroFee() public pure {
        assertEq(ToxicityScoring.scoreToFee(0), 3_000);
    }

    function test_maxScoreFee() public pure {
        assertEq(ToxicityScoring.scoreToFee(10_000), 100_000);
    }

    function test_feeMonotonicallyIncreasing(uint16 a, uint16 b) public pure {
        vm.assume(a <= b);
        assertLe(ToxicityScoring.scoreToFee(a), ToxicityScoring.scoreToFee(b));
    }

    // ── beforeSwap: dynamic fee applied ──────────────────────────────────────

    function test_swapSucceeds_cleanTrader() public {
        // No score set → should use base fee (3_000). Swap must not revert.
        vm.startPrank(CLEAN_TRADER);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_swapSucceeds_toxicTrader() public {
        // Set a high score for the toxic trader, then swap.
        _setScore(TOXIC_TRADER, 8_000);

        vm.startPrank(TOXIC_TRADER);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_toxicTrader_highScoreDoesNotRevert() public {
        _setScore(TOXIC_TRADER, 10_000);

        vm.prank(TOXIC_TRADER);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ── Access control ───────────────────────────────────────────────────────

    function test_setFeedConfig_RevertWhenNotOwner() public {
        vm.expectRevert();
        hook.setFeedConfig(key, bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_setFeedConfig_succeeds() public {
        vm.prank(OWNER);
        hook.setFeedConfig(key, bytes32(uint256(1)), bytes32(uint256(2)));
        assertEq(hook.baseFeedId(key.toId()), bytes32(uint256(1)));
        assertEq(hook.quoteFeedId(key.toId()), bytes32(uint256(2)));
    }

    // ── Registry integration ─────────────────────────────────────────────────

    function test_hookIsAuthorized() public view {
        assertTrue(registry.isAuthorizedHook(address(hook)));
    }

    function test_cleanTrader_scoreRemainsZero() public {
        vm.prank(CLEAN_TRADER);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // No Pyth feeds set → no local toxic detection → score stays 0
        assertEq(registry.scoreOf(CLEAN_TRADER), 0);
    }

    // ── Gas snapshot ─────────────────────────────────────────────────────────

    function test_beforeSwapGas() public {
        uint256 gasBefore = gasleft();
        vm.prank(CLEAN_TRADER);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e15,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("swap gas used:", gasUsed);
        // Sanity: should complete within reasonable gas
        assertLt(gasUsed, 500_000);
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    uint256 constant ATTESTOR_PK = 0xA11CE;

    function _setScore(address wallet, uint16 score) internal {
        address attestor = vm.addr(ATTESTOR_PK);
        vm.prank(OWNER);
        registry.setAttestor(attestor, true);

        IReputationRegistry.Attestation memory a;
        a.wallet   = wallet;
        a.value    = score;
        a.nonce    = 1;
        a.deadline = uint64(block.timestamp + 600);

        // Build digest
        bytes32 domainSep = registry.SCORE_TYPEHASH();
        bytes32 structHash = keccak256(
            abi.encode(domainSep, a.wallet, a.value, a.nonce, a.deadline)
        );
        (
            , string memory name, string memory version,
            uint256 chainId, address verifyingContract,,
        ) = registry.eip712Domain();
        bytes32 domainHash = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            chainId,
            verifyingContract
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainHash, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, digest);
        a.signature = abi.encodePacked(r, s, v);

        registry.updateScore(a);
    }
}
