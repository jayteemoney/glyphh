// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title  IPriceOracle
/// @notice The hook's view of an external reference price, behind one swappable seam.
///
/// @dev    Glyph's L1 arbitrage premium is only as good as the price it compares the pool
///         against, and which oracle supplies that price is an integration detail — not
///         something the fee model should know about. Putting an adapter here means:
///
///           - the hook depends on an interface, not on Pyth;
///           - a second source (Chainlink Data Streams, a TWAP, a redundant feed) can be
///             added later without touching `GlyphHook` at all;
///           - the oracle can be mocked directly in tests, which is how the v1 divergence
///             path went un-covered — it was reachable only through a real `IPyth`.
///
///         The contract every adapter must honour: **a missing, stale or low-confidence
///         price is not an error.** It returns `available = false`, and the hook prices the
///         swap on its remaining layers. An oracle outage must never revert a swap, and must
///         never be able to hold a pool hostage.
interface IPriceOracle {
    /// @notice The reference price for `poolId`'s pair, as token1 per token0, scaled by 1e18.
    /// @return price     Reference price, 1e18-scaled. Meaningless when `available` is false.
    /// @return available Whether a fresh, sufficiently-confident price was obtained.
    function referencePrice(PoolId poolId) external view returns (uint256 price, bool available);
}
