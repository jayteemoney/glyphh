// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {ToxicityScoring} from "./libraries/ToxicityScoring.sol";

contract GlyphHook is IHooks, ImmutableState, Ownable {
    using PoolIdLibrary for PoolKey;

    uint24 public constant DEFAULT_BASE_FEE          = 3_000;
    uint24 public constant MAX_FEE                   = 100_000;
    uint16 public constant LOCAL_IMPACT_BP_THRESHOLD = 200;
    uint32 public constant MAX_PYTH_STALENESS        = 60;

    IReputationRegistry public immutable registry;
    IPyth               public immutable pyth;

    mapping(PoolId => bytes32) public baseFeedId;
    mapping(PoolId => bytes32) public quoteFeedId;
    mapping(bytes32 => uint24) private _pendingFee;
    mapping(bytes32 => bool)   private _pendingToxic;

    event FeedConfigured(PoolId indexed poolId, bytes32 baseFeed, bytes32 quoteFeed);
    event LPDonation(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    constructor(
        IPoolManager _poolManager,
        IReputationRegistry _registry,
        IPyth _pyth,
        address _owner
    ) ImmutableState(_poolManager) Ownable(_owner) {
        registry = _registry;
        pyth     = _pyth;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:                false,
            afterInitialize:                 false,
            beforeAddLiquidity:              false,
            afterAddLiquidity:               false,
            beforeRemoveLiquidity:           false,
            afterRemoveLiquidity:            false,
            beforeSwap:                      true,
            afterSwap:                       true,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            false,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert ImmutableState.NotPoolManager();

        uint16 score     = registry.scoreOf(tx.origin);
        uint24 fee       = ToxicityScoring.scoreToFee(score);
        uint16 impactBps = _estimatePriceImpactBps(key, params);
        bool   toxic     = impactBps >= LOCAL_IMPACT_BP_THRESHOLD;

        if (toxic) fee = MAX_FEE;

        bytes32 swapKey = keccak256(abi.encode(key.toId(), tx.origin));
        _pendingFee[swapKey]   = fee;
        _pendingToxic[swapKey] = toxic;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external returns (bytes4, int128)
    {
        if (msg.sender != address(poolManager)) revert ImmutableState.NotPoolManager();

        bytes32 swapKey = keccak256(abi.encode(key.toId(), tx.origin));
        uint24  charged = _pendingFee[swapKey];
        bool    toxic   = _pendingToxic[swapKey];

        delete _pendingFee[swapKey];
        delete _pendingToxic[swapKey];

        if (charged > DEFAULT_BASE_FEE) {
            // The toxicity premium — the part of the fee above the base fee — is delivered to
            // LPs automatically by the dynamic LP fee (OVERRIDE_FEE_FLAG set in beforeSwap):
            // the PoolManager credits the swap's LP fee to in-range liquidity as fee growth.
            // We surface the premium amount here for observability (dashboard ToxicTradesFeed).
            //
            // Do NOT call poolManager.donate() here: the override fee already pays LPs, so a
            // donate() would (a) double-count and (b) leave the hook owing tokens it never
            // settles, reverting the whole swap with CurrencyNotSettled.
            int128 raw0 = delta.amount0();
            int128 raw1 = delta.amount1();
            uint256 abs0 = raw0 < 0 ? uint256(uint128(-raw0)) : uint256(uint128(raw0));
            uint256 abs1 = raw1 < 0 ? uint256(uint128(-raw1)) : uint256(uint128(raw1));
            uint256 premium0 = FullMath.mulDiv(abs0, charged - DEFAULT_BASE_FEE, 1_000_000);
            uint256 premium1 = FullMath.mulDiv(abs1, charged - DEFAULT_BASE_FEE, 1_000_000);

            if (premium0 > 0 || premium1 > 0) {
                emit LPDonation(key.toId(), premium0, premium1);
            }
        }

        if (toxic) {
            uint16 score    = registry.scoreOf(tx.origin);
            uint16 severity = ToxicityScoring.computeSeverity(LOCAL_IMPACT_BP_THRESHOLD, score);
            registry.reportToxicTrade(tx.origin, address(key.hooks), severity);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    function setFeedConfig(PoolKey calldata key, bytes32 base, bytes32 quote) external onlyOwner {
        PoolId id = key.toId();
        baseFeedId[id]  = base;
        quoteFeedId[id] = quote;
        emit FeedConfigured(id, base, quote);
    }

    function _estimatePriceImpactBps(PoolKey calldata key, SwapParams calldata params)
        internal view returns (uint16 impactBps)
    {
        PoolId  id    = key.toId();
        bytes32 bFeed = baseFeedId[id];
        bytes32 qFeed = quoteFeedId[id];
        if (bFeed == bytes32(0) || qFeed == bytes32(0)) return 0;

        PythStructs.Price memory base;
        PythStructs.Price memory quote;
        try pyth.getPriceNoOlderThan(bFeed, MAX_PYTH_STALENESS) returns (PythStructs.Price memory p) {
            base = p;
        } catch { return 0; }
        try pyth.getPriceNoOlderThan(qFeed, MAX_PYTH_STALENESS) returns (PythStructs.Price memory p) {
            quote = p;
        } catch { return 0; }

        if (base.price <= 0 || quote.price <= 0) return 0;
        if (uint64(base.conf) * 100 > uint64(uint64(int64(base.price)))) return 0;

        uint256 bPrice = uint256(uint64(int64(base.price)));
        uint256 qPrice = uint256(uint64(int64(quote.price)));

        uint256 oraclePrice;
        int32   expDiff = base.expo - quote.expo;
        if (expDiff >= 0) {
            oraclePrice = FullMath.mulDiv(bPrice * _pow10(uint32(expDiff)), 1e18, qPrice);
        } else {
            oraclePrice = FullMath.mulDiv(bPrice, 1e18, qPrice * _pow10(uint32(-expDiff)));
        }
        if (oraclePrice == 0) return 0;

        uint160 sqrtLimit = params.sqrtPriceLimitX96;
        if (sqrtLimit == 0) return 0;

        uint256 effectivePrice = FullMath.mulDiv(
            FullMath.mulDiv(uint256(sqrtLimit), uint256(sqrtLimit), 1 << 64),
            1e18,
            1 << 128
        );
        if (effectivePrice == 0) return 0;

        uint256 diff = effectivePrice > oraclePrice
            ? effectivePrice - oraclePrice
            : oraclePrice - effectivePrice;

        uint256 bps = FullMath.mulDiv(diff, 10_000, oraclePrice);
        impactBps = bps > type(uint16).max ? type(uint16).max : uint16(bps);
    }

    function _pow10(uint32 exp) internal pure returns (uint256 result) {
        result = 1;
        for (uint32 i = 0; i < exp;) {
            result *= 10;
            unchecked { ++i; }
        }
    }
}
