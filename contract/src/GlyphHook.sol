// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseGlyphHook} from "./base/BaseGlyphHook.sol";
import {IGlyphRegistry} from "./interfaces/IGlyphRegistry.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IRebateVault} from "./interfaces/IRebateVault.sol";
import {FlowRisk} from "./libraries/FlowRisk.sol";
import {SwapGuard} from "./libraries/SwapGuard.sol";

/// @title  GlyphHook
/// @notice Prices each swap by how extractive it is, then discounts it by how well the
///         swapper has behaved.
///
/// @dev    v2. The UHI9 judge's objection to v1 was that reputation keyed on `tx.origin` is
///         defeated by rotating EOAs. It was correct, and the fix is not a better identity
///         key — no key survives an attacker willing to fund fresh wallets. The fix is to stop
///         depending on identity for the defence at all:
///
///           L1  arbitrage premium   priced from oracle divergence and swap *direction*.
///                                   No identity. Fires on trade #1 of a brand-new wallet.
///           L2  sandwich surcharge  same-block leg matching (Block 3).
///           L3  reputation          now only ever a discount off L1+L2.
///
///         Rotating a wallet no longer returns an attacker to free. It returns them to
///         *unproven*, and forfeits trust that took settled benign volume to earn.
contract GlyphHook is BaseGlyphHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ── Immutables ────────────────────────────────────────────────────────────

    IGlyphRegistry public immutable registry;

    // ── Configuration ─────────────────────────────────────────────────────────

    /// @notice Divergence at or above which a swap is reported as toxic, in bps.
    uint16 public constant TOXIC_DIVERGENCE_BPS = 200;

    IPriceOracle public oracle;

    /// @notice Escrow that returns sandwich surcharges to the sandwiched trader.
    IRebateVault public vault;

    /// @notice Per-pool record of what has happened in the current block.
    /// @dev    Persistent, not transient, and that is not an oversight. A sandwich's legs are
    ///         separate *transactions* in one block; EIP-1153 storage is cleared between them
    ///         and cannot see across. `SwapGuard` handles the intra-transaction case; this
    ///         handles the intra-block one. Fields are meaningful only while
    ///         `blockNumber == block.number`, so a stale record is never read, only overwritten.
    mapping(PoolId poolId => BlockState) private _blockState;

    /// @dev A sliding window over the last two swaps in the pool's current block. Two slots:
    ///      (blockNumber, prev2, dir2) and (prev1, dir1).
    struct BlockState {
        uint64 blockNumber;
        address prev2; // the swap two back
        bool dir2;
        address prev1; // the immediately preceding swap
        bool dir1;
    }

    /// @notice Routers trusted to name the real swapper in `hookData`.
    mapping(address router => bool trusted) public trustedRouter;

    /// @notice Contracts that have declared themselves self-custodial accounts.
    mapping(address account => bool registered) public isSmartAccount;

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Every term of the quoted fee, separately.
    /// @dev    Emitted decomposed rather than as a single number so the dashboard can show
    ///         *why* a swap was priced the way it was. A fee a trader cannot account for is
    ///         indistinguishable from an arbitrary one.
    event FeeQuoted(
        PoolId indexed poolId,
        address indexed swapper,
        uint24 baseFee,
        uint24 arbPremium,
        uint24 unprovenPremium,
        uint24 toxicPremium,
        uint24 trustDiscount,
        uint24 finalFee
    );

    /// @notice A sandwich's closing leg was detected and surcharged.
    event SandwichDetected(
        PoolId indexed poolId, address indexed attacker, address indexed victim, Currency currency, uint256 rebate
    );

    event OracleUpdated(address indexed oracle);
    event VaultUpdated(address indexed vault);
    event TrustedRouterSet(address indexed router, bool trusted);
    event SmartAccountRegistered(address indexed account);

    // ── Construction ──────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager, IGlyphRegistry _registry, IPriceOracle _oracle, address _owner)
        BaseGlyphHook(_poolManager)
        Ownable(_owner)
    {
        registry = _registry;
        oracle = _oracle;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            // Enabled now though unused until the rebate path lands, because permissions are
            // encoded in the hook's address: turning this on later would mean mining a new
            // address and redeploying every pool.
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ── Swap callbacks ────────────────────────────────────────────────────────

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        address swapper = _swapper(sender, hookData);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        (uint256 divergenceBps, bool closesGap) = _divergence(poolId, sqrtPriceX96, params.zeroForOne);
        uint256 sizeBps = _sizeBps(poolId, sqrtPriceX96, params);

        uint16 score = registry.scoreOf(swapper);
        uint16 trust = registry.trustOf(swapper);

        uint24 fee = FlowRisk.assembleFee(
            FlowRisk.Inputs({
                divergenceBps: divergenceBps,
                closesGap: closesGap,
                sizeBps: sizeBps,
                score: score,
                trust: trust
            })
        );

        emit FeeQuoted(
            poolId,
            swapper,
            FlowRisk.BASE_FEE,
            FlowRisk.arbPremium(divergenceBps, closesGap),
            trust == 0 ? FlowRisk.unprovenPremium(sizeBps) : 0,
            FlowRisk.toxicPremium(score),
            FlowRisk.trustDiscount(trust),
            fee
        );

        (bool sandwichClose, address victim) = _trackBlock(poolId, swapper, params.zeroForOne);

        uint16 divergence16 = divergenceBps > type(uint16).max ? type(uint16).max : uint16(divergenceBps);
        SwapGuard.store(
            SwapGuard.nextLeg(),
            SwapGuard.Pending({
                fee: fee,
                divergenceBps: divergence16,
                toxic: closesGap && divergenceBps >= TOXIC_DIVERGENCE_BPS,
                sandwichClose: sandwichClose,
                victim: victim
            })
        );

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        SwapGuard.Pending memory pending = SwapGuard.load(SwapGuard.currentLeg());

        if (pending.sandwichClose) {
            int128 taken = _payRebate(key, params, delta, pending, _swapper(sender, hookData));
            if (taken != 0) return (IHooks.afterSwap.selector, taken);
        }

        if (pending.toxic) {
            address swapper = _swapper(sender, hookData);
            // Severity carries the *measured* divergence. v1 passed the constant threshold
            // here, so a 10,000 bp attack and a 201 bp one scored identically and the registry
            // learned nothing about magnitude.
            uint16 severity = _severity(pending.divergenceBps, registry.scoreOf(swapper));
            registry.reportToxicSwap(swapper, PoolId.unwrap(key.toId()), severity);
        }

        // The premium above base is already paid to in-range LPs by the dynamic fee override
        // set in beforeSwap: the PoolManager credits the swap's LP fee as fee growth. Calling
        // donate() here as well would double-pay and leave the hook owing tokens it never
        // settles, reverting the swap with CurrencyNotSettled.
        return (IHooks.afterSwap.selector, int128(0));
    }

    // ── Sandwich detection ────────────────────────────────────────────────────

    /// @notice Record this swap against the pool's current block, and report whether it closes
    ///         a sandwich opened earlier in the same block.
    ///
    /// @dev    The pattern is three legs in one block: an opener takes a direction, a *different*
    ///         identity trades the same direction at the worse price the opener created, and the
    ///         opener reverses out. It is the reversal-with-someone-in-between that identifies a
    ///         sandwich; two legs alone are just a round trip, and the same two legs in different
    ///         blocks are not a sandwich at all.
    ///
    ///         Both negative cases are tested, and they matter more than the positive one: a
    ///         false positive here charges an honest trader the maximum fee.
    function _trackBlock(PoolId poolId, address swapper, bool zeroForOne)
        internal
        returns (bool sandwichClose, address victim)
    {
        BlockState storage bs = _blockState[poolId];

        if (bs.blockNumber != uint64(block.number)) {
            bs.blockNumber = uint64(block.number);
            bs.prev2 = address(0);
            bs.dir2 = false;
            bs.prev1 = swapper;
            bs.dir1 = zeroForOne;
            return (false, address(0));
        }

        // The closing leg of a sandwich reverses a position the same identity opened exactly
        // two swaps ago, with a *different* identity having traded the same direction in
        // between. Matching on a two-swap window rather than on the block's first swapper is
        // what lets this fire on a sandwich that starts midway through a busy block — which is
        // where essentially all real ones start.
        if (
            swapper == bs.prev2 && zeroForOne != bs.dir2 && bs.prev1 != address(0) && bs.prev1 != swapper
                && bs.dir1 == bs.dir2
        ) {
            victim = bs.prev1;
            // Reset the window so one victim is compensated once, however many times the
            // attacker reverses within the block.
            bs.prev2 = address(0);
            bs.dir2 = false;
            bs.prev1 = swapper;
            bs.dir1 = zeroForOne;
            return (true, victim);
        }

        bs.prev2 = bs.prev1;
        bs.dir2 = bs.dir1;
        bs.prev1 = swapper;
        bs.dir1 = zeroForOne;
        return (false, address(0));
    }

    /// @notice Take the sandwich surcharge from the closing leg and escrow it for the victim.
    ///
    /// @dev    The split is the point. A sandwich close is priced at MAX_FEE in total, but only
    ///         the normally-assembled part goes to LPs through the fee override — the remainder
    ///         is taken here as a hook delta and credited to the trader who was squeezed. Paying
    ///         it to LPs instead would leave the actual victim exactly as badly off.
    ///
    ///         Mechanically: `take` moves tokens to the vault and leaves the hook owing that
    ///         amount, and the returned positive delta credits the hook the same amount, so the
    ///         hook's books net to zero and the swapper is the one debited.
    ///
    ///         Charged on the *unspecified* side and only when the swapper is receiving it, so
    ///         the surcharge always comes out of proceeds rather than adding an unbounded extra
    ///         obligation to an exact-output swap.
    function _payRebate(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        SwapGuard.Pending memory pending,
        address attacker
    ) internal returns (int128) {
        if (address(vault) == address(0) || pending.victim == address(0)) return 0;

        bool unspecifiedIsCurrency1 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency currency = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
        int128 unspecifiedAmount = unspecifiedIsCurrency1 ? delta.amount1() : delta.amount0();
        if (unspecifiedAmount <= 0) return 0;

        uint256 surchargePips = FlowRisk.MAX_FEE - pending.fee;
        uint256 amount = FullMath.mulDiv(uint256(uint128(unspecifiedAmount)), surchargePips, 1_000_000);
        if (amount == 0) return 0;

        poolManager.take(currency, address(vault), amount);
        vault.credit(currency, pending.victim, amount);

        emit SandwichDetected(key.toId(), attacker, pending.victim, currency, amount);

        // A sandwich is the strongest toxicity signal available, and unlike the oracle path it
        // needs no external price to establish.
        registry.reportToxicSwap(attacker, PoolId.unwrap(key.toId()), FlowRisk.MAX_SCORE);

        return int128(uint128(amount));
    }

    // ── Identity ──────────────────────────────────────────────────────────────

    /// @notice Best available identity for the account whose flow this is.
    ///
    /// @dev    Three tiers, all heuristics, in descending order of confidence:
    ///
    ///           1. A trusted router naming the user in `hookData`. The production path — a
    ///              router that wants its users to carry their own reputation opts in, and
    ///              multi-hop routing stops flattening every user into one identity.
    ///           2. A self-registered smart account. Under ERC-4337 `tx.origin` is the
    ///              *bundler*, so v1 scored the bundler and every 4337 user shared its
    ///              reputation. Registering makes the account itself the subject.
    ///           3. `tx.origin`. The common EOA case, and still spoofable by rotation.
    ///
    ///         That tier 3 remains imperfect is why reputation is a discount and not the
    ///         defence. A wrong identity costs an honest trader a discount they had earned; it
    ///         does not let an extractive swap through, because L1 never consults identity.
    function _swapper(address sender, bytes calldata hookData) internal view returns (address) {
        if (trustedRouter[sender] && hookData.length >= 32) {
            address named = abi.decode(hookData, (address));
            if (named != address(0)) return named;
        }
        if (isSmartAccount[sender]) return sender;
        return tx.origin;
    }

    // ── Pricing inputs ────────────────────────────────────────────────────────

    /// @notice Pool-versus-oracle divergence, and whether this swap closes it.
    ///
    /// @dev    Direction is the entire point, and it is what v1 got wrong. v1 derived the
    ///         swap's price from `params.sqrtPriceLimitX96` — a slippage bound the *swapper*
    ///         supplies, and which every router sets to the extreme tick. With feeds
    ///         configured that made divergence saturate on every swap, so honest retail read
    ///         as maximally toxic; the feature had to be disabled in production to ship.
    ///
    ///         Here both inputs are pool or oracle state and neither is swapper-controlled.
    ///         A swap that moves the pool *toward* the oracle is capturing the divergence —
    ///         that is the arbitrage LPs lose to. A swap that moves it *away* is uninformed
    ///         flow, which LPs want, and is never surcharged however large it is.
    function _divergence(PoolId poolId, uint160 sqrtPriceX96, bool zeroForOne)
        internal
        view
        returns (uint256 divergenceBps, bool closesGap)
    {
        if (address(oracle) == address(0) || sqrtPriceX96 == 0) return (0, false);

        (uint256 referencePrice, bool available) = oracle.referencePrice(poolId);
        if (!available || referencePrice == 0) return (0, false);

        uint256 poolPrice = _poolPrice(sqrtPriceX96);
        if (poolPrice == 0) return (0, false);

        uint256 diff = poolPrice > referencePrice ? poolPrice - referencePrice : referencePrice - poolPrice;
        divergenceBps = FullMath.mulDiv(diff, 10_000, referencePrice);

        // Pool rich in token1 terms → selling token0 into it closes the gap, and vice versa.
        closesGap = (poolPrice > referencePrice) == zeroForOne;
    }

    /// @dev token1 per token0, 1e18-scaled. Squaring in two steps keeps the 512-bit
    ///      intermediate inside FullMath rather than overflowing uint256.
    function _poolPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        return FullMath.mulDiv(priceX96, 1e18, 1 << 96);
    }

    /// @notice Swap notional as bps of the pool's in-range reserve on the specified side.
    ///
    /// @dev    This is what keeps the unproven-identity premium off retail: the burden of
    ///         proof scales with how much the swap could actually move, not with a flat tax.
    ///
    ///         `liquidity` is L, not a token balance. For a position spanning the current
    ///         price the in-range reserves are approximately `L / sqrtP` of token0 and
    ///         `L * sqrtP` of token1; concentrated positions hold less than that, so this
    ///         *overstates* the reserve and therefore *understates* size. The error is
    ///         conservative in the direction that matters — it can only quote too low a
    ///         premium, never surcharge an honest trader for a swap smaller than it looks.
    function _sizeBps(PoolId poolId, uint160 sqrtPriceX96, SwapParams calldata params)
        internal
        view
        returns (uint256)
    {
        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0 || sqrtPriceX96 == 0) return 0;

        int256 specified = params.amountSpecified;
        uint256 amount = specified < 0 ? uint256(-specified) : uint256(specified);
        if (amount == 0) return 0;

        // Exact-input names the input currency; exact-output names the output currency.
        bool specifiedIsCurrency0 = (specified < 0) == params.zeroForOne;

        uint256 reserve = specifiedIsCurrency0
            ? FullMath.mulDiv(liquidity, 1 << 96, sqrtPriceX96)
            : FullMath.mulDiv(liquidity, sqrtPriceX96, 1 << 96);
        if (reserve == 0) return 0;

        uint256 bps = FullMath.mulDiv(amount, 10_000, reserve);
        return bps > type(uint16).max ? type(uint16).max : bps;
    }

    /// @dev Blend measured divergence with standing reputation, capped at MAX_SCORE.
    function _severity(uint16 divergenceBps, uint16 score) internal pure returns (uint16) {
        uint256 combined = (uint256(divergenceBps) + uint256(score)) / 2;
        return combined > FlowRisk.MAX_SCORE ? FlowRisk.MAX_SCORE : uint16(combined);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setOracle(IPriceOracle _oracle) external onlyOwner {
        oracle = _oracle;
        emit OracleUpdated(address(_oracle));
    }

    function setVault(IRebateVault _vault) external onlyOwner {
        vault = _vault;
        emit VaultUpdated(address(_vault));
    }

    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        trustedRouter[router] = trusted;
        emit TrustedRouterSet(router, trusted);
    }

    /// @notice Declare the caller a self-custodial account, so its own address is scored.
    /// @dev    Self-registration only. A contract can claim itself and nothing else, so this
    ///         cannot be used to attach one account's reputation to another.
    function registerSmartAccount() external {
        isSmartAccount[msg.sender] = true;
        emit SmartAccountRegistered(msg.sender);
    }
}
