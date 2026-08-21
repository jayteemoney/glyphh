// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title  SettablePriceOracle
/// @notice An `IPriceOracle` whose price is written by its owner.
///
/// @dev    For local demos and testnets, where no real feed exists for a pair of mock tokens.
///         It exists so the L1 arbitrage layer can be *shown* rather than described: the demo
///         moves the reference price, and the next swap that closes the gap is surcharged live.
///
///         Deliberately not for production — a mutable owner-set price is a trusted price, and
///         the whole point of L1 is that its input is not controlled by anyone who benefits
///         from the swap. `PythPriceOracle` is the real adapter. Both satisfy the same interface,
///         which is why the hook needs no knowledge of which one it is talking to.
contract SettablePriceOracle is IPriceOracle, Ownable {
    mapping(PoolId poolId => uint256 price) public priceOf;
    mapping(PoolId poolId => bool live) public isLive;

    event PriceSet(PoolId indexed poolId, uint256 price, bool live);

    constructor(address _owner) Ownable(_owner) {}

    function setPrice(PoolId poolId, uint256 price, bool live) external onlyOwner {
        priceOf[poolId] = price;
        isLive[poolId] = live;
        emit PriceSet(poolId, price, live);
    }

    /// @inheritdoc IPriceOracle
    function referencePrice(PoolId poolId) external view override returns (uint256, bool) {
        return (priceOf[poolId], isLive[poolId]);
    }
}
