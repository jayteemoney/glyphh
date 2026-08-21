// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Settable reference price, for exercising the L1 divergence path directly.
/// @dev    The whole reason `IPriceOracle` exists. v1 reached its oracle only through a real
///         `IPyth`, so every test constructed the hook with `IPyth(address(0))` and the
///         divergence branch was never executed once across 69 tests.
contract MockPriceOracle is IPriceOracle {
    mapping(PoolId => uint256) public price;
    mapping(PoolId => bool) public isAvailable;

    function set(PoolId poolId, uint256 _price, bool _available) external {
        price[poolId] = _price;
        isAvailable[poolId] = _available;
    }

    function referencePrice(PoolId poolId) external view override returns (uint256, bool) {
        return (price[poolId], isAvailable[poolId]);
    }
}
