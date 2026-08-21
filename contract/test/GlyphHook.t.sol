// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseGlyphHook} from "../src/base/BaseGlyphHook.sol";
import {GlyphHook} from "../src/GlyphHook.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";
import {IGlyphRegistry} from "../src/interfaces/IGlyphRegistry.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {FlowRisk} from "../src/libraries/FlowRisk.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract GlyphHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using StateLibrary for PoolManager;

    uint256 constant ATTESTOR_PK = 0xA11CE;
    address constant OWNER = address(0xD1);
    address constant CLEAN = address(0xC1);
    address constant TOXIC = address(0xBA);

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    ReputationRegistry registry;
    MockPriceOracle oracle;
    GlyphHook hook;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId poolId;

    function setUp() public {
        manager = new PoolManager(OWNER);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        registry = new ReputationRegistry(OWNER);
        oracle = new MockPriceOracle();

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(address(manager), address(registry), address(oracle), OWNER);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(GlyphHook).creationCode, args);

        hook = new GlyphHook{salt: salt}(
            IPoolManager(address(manager)), IGlyphRegistry(address(registry)), IPriceOracle(address(oracle)), OWNER
        );

        vm.startPrank(OWNER);
        registry.setHook(address(hook), true);
        registry.setAttestor(vm.addr(ATTESTOR_PK), true);
        vm.stopPrank();

        MockERC20 tA = new MockERC20("TokenA", "TA", 18);
        MockERC20 tB = new MockERC20("TokenB", "TB", 18);
        (token0, token1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 100_000e18, salt: bytes32(0)}),
            ""
        );

        _fund(CLEAN);
        _fund(TOXIC);
    }

    function _fund(address who) internal {
        token0.mint(who, 100_000e18);
        token1.mint(who, 100_000e18);
        vm.startPrank(who);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The two-argument form sets BOTH msg.sender and tx.origin. v1's tests used the
    ///      one-argument form, so `scoreOf(tx.origin)` inside the hook read Foundry's default
    ///      sender rather than the pranked trader — meaning the "toxic trader pays more" tests
    ///      never once exercised a non-base fee.
    function _swap(address who, bool zeroForOne, int256 amount) internal {
        vm.prank(who, who);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Reads the fee the hook actually quoted, from the FeeQuoted event.
    function _swapAndReadFee(address who, bool zeroForOne, int256 amount) internal returns (uint24 fee) {
        vm.recordLogs();
        _swap(who, zeroForOne, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("FeeQuoted(bytes32,address,uint24,uint24,uint24,uint24,uint24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (,,,,, uint24 finalFee) =
                    abi.decode(logs[i].data, (uint24, uint24, uint24, uint24, uint24, uint24));
                return finalFee;
            }
        }
        revert("FeeQuoted not emitted");
    }

    function _setScore(address wallet, uint16 value) internal {
        _attest(wallet, value, true);
    }

    function _setTrust(address wallet, uint16 value) internal {
        _attest(wallet, value, false);
    }

    function _attest(address wallet, uint16 value, bool isScore) internal {
        uint64 deadline = uint64(block.timestamp + 600);
        uint32 nonce = isScore ? registry.scoreDataOf(wallet).nonce + 1 : registry.trustDataOf(wallet).nonce + 1;
        bytes32 typehash = isScore ? registry.SCORE_TYPEHASH() : registry.TRUST_TYPEHASH();
        bytes32 structHash = keccak256(abi.encode(typehash, wallet, value, nonce, deadline));
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = registry.eip712Domain();
        bytes32 domainHash = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifying
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ATTESTOR_PK, keccak256(abi.encodePacked("\x19\x01", domainHash, structHash)));
        bytes memory sig = abi.encodePacked(r, s, v);

        if (isScore) {
            registry.updateScore(
                IReputationRegistry.Attestation({
                    wallet: wallet,
                    value: value,
                    nonce: nonce,
                    deadline: deadline,
                    signature: sig
                })
            );
        } else {
            registry.updateTrust(
                IGlyphRegistry.TrustAttestation({
                    wallet: wallet,
                    value: value,
                    nonce: nonce,
                    deadline: deadline,
                    signature: sig
                })
            );
        }
    }

    /// @dev Sets the oracle to the pool's own current price, then skews it by `bps`.
    function _skewOracle(int256 bps) internal {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        uint256 poolPrice = FullMath.mulDiv(priceX96, 1e18, 1 << 96);
        uint256 skewed = uint256(int256(poolPrice) + (int256(poolPrice) * bps) / 10_000);
        oracle.set(poolId, skewed, true);
    }

    // ── Permissions and construction ─────────────────────────────────────────

    function test_permissions_matchDeployedAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.beforeSwapReturnDelta);
    }

    /// @dev The reason BaseGlyphHook validates in its constructor: a hook whose address does
    ///      not encode its declared permissions must fail loudly at deploy time.
    function test_deploy_RevertWhenAddressLacksPermissionBits() public {
        vm.expectRevert();
        new GlyphHook{salt: bytes32(uint256(1))}(
            IPoolManager(address(manager)), IGlyphRegistry(address(registry)), IPriceOracle(address(oracle)), OWNER
        );
    }

    function test_unpermissionedCallbackReverts() public {
        vm.prank(address(manager));
        vm.expectRevert();
        hook.beforeDonate(address(this), key, 0, 0, "");
    }

    function test_beforeSwap_RevertWhenNotPoolManager() public {
        vm.expectRevert();
        hook.beforeSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
    }

    // ── L1: directional arbitrage premium ────────────────────────────────────

    function test_noOracle_chargesBaseFee() public {
        oracle.set(poolId, 0, false);
        assertEq(_swapAndReadFee(CLEAN, true, -1e15), FlowRisk.BASE_FEE);
    }

    function test_poolAtOracle_chargesBaseFee() public {
        _skewOracle(0);
        assertEq(_swapAndReadFee(CLEAN, true, -1e15), FlowRisk.BASE_FEE);
    }

    /// @dev Pool is above the oracle, so selling token0 into it closes the gap: this is the
    ///      arbitrage, and it pays.
    function test_gapClosingSwap_paysArbPremium() public {
        _skewOracle(-100); // oracle 1% below pool
        uint24 fee = _swapAndReadFee(CLEAN, true, -1e15);
        assertGt(fee, FlowRisk.BASE_FEE);
    }

    /// @dev The test that proves the model is *directional* rather than merely divergence-
    ///      sensitive. Same pool, same divergence, same trader, opposite direction: this swap
    ///      pushes the pool further from the oracle, which is uninformed flow LPs want, and it
    ///      pays nothing extra.
    function test_gapWideningSwap_paysNothingExtra() public {
        _skewOracle(-100);
        assertEq(_swapAndReadFee(CLEAN, false, -1e15), FlowRisk.BASE_FEE);
    }

    function test_arbPremium_scalesWithDivergence() public {
        _skewOracle(-50);
        uint24 small = _swapAndReadFee(CLEAN, true, -1e14);
        _skewOracle(-300);
        uint24 large = _swapAndReadFee(CLEAN, true, -1e14);
        assertGt(large, small);
    }

    function test_staleOracle_neverRevertsAndNeverSurcharges() public {
        _skewOracle(-500);
        oracle.set(poolId, 0, false); // feed goes unavailable mid-flight
        assertEq(_swapAndReadFee(CLEAN, true, -1e15), FlowRisk.BASE_FEE);
    }

    /// @dev An identity-free defence: a wallet with no history at all still pays on trade #1.
    ///      This is the direct answer to "a sandwicher just rotates EOAs".
    function test_freshWallet_paysArbPremiumOnFirstTrade() public {
        address fresh = address(0xFAFA);
        _fund(fresh);
        assertEq(registry.scoreOf(fresh), 0);
        assertEq(registry.trustOf(fresh), 0);

        _skewOracle(-200);
        assertGt(_swapAndReadFee(fresh, true, -1e15), FlowRisk.BASE_FEE);
    }

    // ── L3: reputation as a discount ─────────────────────────────────────────

    function test_toxicWallet_paysMoreThanClean() public {
        uint24 cleanFee = _swapAndReadFee(CLEAN, true, -1e15);
        _setScore(TOXIC, 8_000);
        uint24 toxicFee = _swapAndReadFee(TOXIC, true, -1e15);
        assertGt(toxicFee, cleanFee);
    }

    function test_trustedWallet_paysBelowBase() public {
        _setTrust(CLEAN, 10_000);
        assertEq(_swapAndReadFee(CLEAN, true, -1e15), FlowRisk.FLOOR_FEE);
    }

    function test_trustDiscount_isProportional() public {
        _setTrust(CLEAN, 5_000);
        uint24 fee = _swapAndReadFee(CLEAN, true, -1e15);
        assertLt(fee, FlowRisk.BASE_FEE);
        assertGt(fee, FlowRisk.FLOOR_FEE);
    }

    /// @dev The retail carve-out. A small swap from a wallet with no record pays base fee —
    ///      the inversion must not become a tax on ordinary traders.
    function test_smallSwapFromUnknownWallet_paysBaseFee() public {
        assertEq(_swapAndReadFee(CLEAN, true, -1e15), FlowRisk.BASE_FEE);
    }

    /// @dev ...while a large one from that same wallet does not.
    function test_largeSwapFromUnknownWallet_paysUnprovenPremium() public {
        assertGt(_swapAndReadFee(CLEAN, true, -2_000e18), FlowRisk.BASE_FEE);
    }

    function test_provenWallet_avoidsUnprovenPremium() public {
        uint24 unproven = _swapAndReadFee(CLEAN, true, -2_000e18);
        _setTrust(TOXIC, 10_000);
        uint24 proven = _swapAndReadFee(TOXIC, true, -2_000e18);
        assertLt(proven, unproven);
    }

    // ── Identity resolution ──────────────────────────────────────────────────

    function test_identity_defaultsToTxOrigin() public {
        _setScore(TOXIC, 9_000);
        assertGt(_swapAndReadFee(TOXIC, true, -1e15), _swapAndReadFee(CLEAN, true, -1e15));
    }

    /// @dev Under ERC-4337 tx.origin is the bundler. v1 scored the bundler, so every user of a
    ///      given bundler shared one reputation. A registered account is scored as itself.
    /// @dev Tier 2 covers accounts that unlock the PoolManager themselves, so the account is
    ///      `sender`. Exercised directly rather than through the test router, because a router
    ///      in the middle makes the router `sender` — that case is tier 1, tested below.
    ///
    ///      The v1 bug this closes: under ERC-4337 `tx.origin` is the *bundler*, so every user
    ///      of a given bundler shared one reputation and one fee.
    function test_identity_registeredSmartAccountIsScored() public {
        SmartAccount account = new SmartAccount();
        account.register(hook);

        address bundler = address(0xB0107);
        vm.recordLogs();
        vm.prank(address(manager), bundler);
        hook.beforeSwap(
            address(account),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        assertEq(_lastQuotedSwapper(), address(account));
    }

    /// @dev The same call from an *unregistered* contract falls through to tx.origin — which
    ///      is precisely the bundler-scoring bug, retained here as the baseline it fixes.
    function test_identity_unregisteredContractFallsThroughToOrigin() public {
        SmartAccount account = new SmartAccount();

        address bundler = address(0xB0107);
        vm.recordLogs();
        vm.prank(address(manager), bundler);
        hook.beforeSwap(
            address(account),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        assertEq(_lastQuotedSwapper(), bundler);
    }

    function test_identity_trustedRouterNamesSwapper() public {
        vm.prank(OWNER);
        hook.setTrustedRouter(address(swapRouter), true);

        address named = address(0xBEEF);
        vm.recordLogs();
        vm.prank(CLEAN, CLEAN);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(named)
        );
        assertEq(_lastQuotedSwapper(), named);
    }

    function test_identity_untrustedRouterHookDataIsIgnored() public {
        vm.recordLogs();
        vm.prank(CLEAN, CLEAN);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(0xBEEF))
        );
        assertEq(_lastQuotedSwapper(), CLEAN);
    }

    function _lastQuotedSwapper() internal returns (address) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("FeeQuoted(bytes32,address,uint24,uint24,uint24,uint24,uint24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) return address(uint160(uint256(logs[i].topics[2])));
        }
        revert("FeeQuoted not emitted");
    }

    // ── Toxic reporting ──────────────────────────────────────────────────────

    function test_toxicSwap_reportsWithMeasuredSeverity() public {
        _skewOracle(-1_000); // 10% divergence, far past the 200bp threshold
        _swap(CLEAN, true, -1e15);
        assertGt(registry.scoreOf(CLEAN), 0);
    }

    function test_cleanSwap_isNotReported() public {
        _skewOracle(0);
        _swap(CLEAN, true, -1e15);
        assertEq(registry.scoreOf(CLEAN), 0);
    }

    /// @dev v1 passed the constant threshold into severity, so every toxic swap scored the
    ///      same regardless of magnitude. Severity must track the measured divergence.
    function test_severityTracksDivergenceMagnitude() public {
        _skewOracle(-300);
        _swap(CLEAN, true, -1e14);
        uint16 mild = registry.scoreOf(CLEAN);

        _skewOracle(-5_000);
        _swap(TOXIC, true, -1e14);
        uint16 severe = registry.scoreOf(TOXIC);

        assertGt(severe, mild);
    }

    // ── Gas ──────────────────────────────────────────────────────────────────

    function test_swapGas() public {
        _skewOracle(0);
        uint256 before = gasleft();
        _swap(CLEAN, true, -1e15);
        uint256 used = before - gasleft();
        console2.log("swap gas:", used);
        assertLt(used, 500_000);
    }
}

/// @notice Stand-in for a smart account that interacts with the PoolManager on its own
///         behalf, rather than through a router.
contract SmartAccount {
    function register(GlyphHook hook) external {
        hook.registerSmartAccount();
    }
}

/// @notice BaseGlyphHook's reverting defaults.
///
/// @dev    v1 implemented all ten callbacks as no-op stubs that returned their selectors,
///         which is worse than not implementing them: a stub is indistinguishable from a real
///         implementation to anyone reading the interface, and if a permission bit were ever
///         set by accident the stub would quietly accept the call. Reverting defaults mean an
///         unpermissioned callback that somehow gets invoked fails loudly instead.
///
///         These assertions exist so that property cannot regress silently.
contract BaseGlyphHookDefaultsTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager manager;
    ReputationRegistry registry;
    MockPriceOracle oracle;
    GlyphHook hook;
    PoolKey key;

    function setUp() public {
        manager = new PoolManager(address(0xD1));
        registry = new ReputationRegistry(address(0xD1));
        oracle = new MockPriceOracle();

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(address(manager), address(registry), address(oracle), address(0xD1));
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(GlyphHook).creationCode, args);
        hook = new GlyphHook{salt: salt}(
            IPoolManager(address(manager)),
            IGlyphRegistry(address(registry)),
            IPriceOracle(address(oracle)),
            address(0xD1)
        );

        key = PoolKey({
            currency0: Currency.wrap(address(1)),
            currency1: Currency.wrap(address(2)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function test_beforeInitialize_reverts() public {
        vm.expectRevert(BaseGlyphHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, 0);
    }

    function test_afterInitialize_reverts() public {
        vm.expectRevert(BaseGlyphHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function test_beforeAddLiquidity_reverts() public {
        ModifyLiquidityParams memory p;
        vm.expectRevert(BaseGlyphHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, p, "");
    }

    function test_afterAddLiquidity_reverts() public {
        ModifyLiquidityParams memory p;
        vm.expectRevert(BaseGlyphHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function test_beforeRemoveLiquidity_reverts() public {
        ModifyLiquidityParams memory p;
        vm.expectRevert(BaseGlyphHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, p, "");
    }

    function test_afterRemoveLiquidity_reverts() public {
        ModifyLiquidityParams memory p;
        vm.expectRevert(BaseGlyphHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, p, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function test_beforeDonate_reverts() public {
        vm.expectRevert(BaseGlyphHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");
    }

    function test_afterDonate_reverts() public {
        vm.expectRevert(BaseGlyphHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 0, 0, "");
    }
}
