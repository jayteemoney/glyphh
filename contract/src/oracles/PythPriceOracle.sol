// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title  PythPriceOracle
/// @notice `IPriceOracle` adapter over Pyth pull feeds.
///
/// @dev    Lifted out of the hook in v2. Keeping oracle mechanics — exponent alignment,
///         staleness, confidence — inside `beforeSwap` meant the divergence path could only be
///         exercised through a real `IPyth`, which is why v1 shipped it with zero test
///         coverage and a bug that made it unusable. Behind an interface it is mockable, and
///         a second source can be added without the hook noticing.
///
///         Every failure mode returns `available = false` rather than reverting. An oracle
///         that can revert inside `beforeSwap` is an oracle that can halt a pool.
contract PythPriceOracle is IPriceOracle, Ownable {
    /// @notice Reject prices older than this many seconds.
    uint32 public constant MAX_STALENESS = 60;

    /// @notice Reject prices whose confidence interval exceeds this share of the price, in bps.
    ///         A wide band means Pyth itself is unsure; acting on it would let oracle noise
    ///         quote the max fee to honest flow.
    uint256 public constant MAX_CONF_BPS = 100; // 1%

    IPyth public immutable pyth;

    mapping(PoolId poolId => bytes32 feedId) public baseFeedId;
    mapping(PoolId poolId => bytes32 feedId) public quoteFeedId;

    event FeedConfigured(PoolId indexed poolId, bytes32 baseFeed, bytes32 quoteFeed);

    constructor(IPyth _pyth, address _owner) Ownable(_owner) {
        pyth = _pyth;
    }

    /// @notice Point a pool at its base/quote Pyth feeds. Clearing both disables L1 for it.
    function setFeeds(PoolId poolId, bytes32 base, bytes32 quote) external onlyOwner {
        baseFeedId[poolId] = base;
        quoteFeedId[poolId] = quote;
        emit FeedConfigured(poolId, base, quote);
    }

    /// @inheritdoc IPriceOracle
    /// @dev Returns token1-per-token0 scaled by 1e18, matching how the pool's own `slot0`
    ///      price is expressed, so the hook can subtract them directly.
    function referencePrice(PoolId poolId) external view override returns (uint256 price, bool available) {
        bytes32 bFeed = baseFeedId[poolId];
        bytes32 qFeed = quoteFeedId[poolId];
        if (bFeed == bytes32(0) || qFeed == bytes32(0)) return (0, false);
        if (address(pyth) == address(0)) return (0, false);

        PythStructs.Price memory base;
        PythStructs.Price memory quote;

        try pyth.getPriceNoOlderThan(bFeed, MAX_STALENESS) returns (PythStructs.Price memory p) {
            base = p;
        } catch {
            return (0, false);
        }
        try pyth.getPriceNoOlderThan(qFeed, MAX_STALENESS) returns (PythStructs.Price memory p) {
            quote = p;
        } catch {
            return (0, false);
        }

        if (base.price <= 0 || quote.price <= 0) return (0, false);

        uint256 basePrice = uint256(uint64(int64(base.price)));
        uint256 quotePrice = uint256(uint64(int64(quote.price)));

        // Confidence gate on both legs, not just the base — a wide quote band distorts the
        // ratio exactly as much as a wide base one.
        if (uint256(base.conf) * 10_000 > basePrice * MAX_CONF_BPS) return (0, false);
        if (uint256(quote.conf) * 10_000 > quotePrice * MAX_CONF_BPS) return (0, false);

        // price = (base / quote), with the feeds' exponents reconciled.
        int32 expDiff = base.expo - quote.expo;
        if (expDiff >= 0) {
            uint256 scale = _pow10(uint32(expDiff));
            if (scale == 0) return (0, false);
            price = FullMath.mulDiv(basePrice * scale, 1e18, quotePrice);
        } else {
            uint256 scale = _pow10(uint32(-expDiff));
            if (scale == 0) return (0, false);
            price = FullMath.mulDiv(basePrice, 1e18, quotePrice * scale);
        }

        available = price != 0;
    }

    function _pow10(uint32 exp) private pure returns (uint256 result) {
        // Beyond 1e77 the result would overflow uint256; signal unusable rather than wrap.
        if (exp > 77) return 0;
        result = 1;
        for (uint32 i = 0; i < exp;) {
            result *= 10;
            unchecked {
                ++i;
            }
        }
    }
}
