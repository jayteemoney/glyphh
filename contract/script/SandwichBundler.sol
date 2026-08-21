// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Executes the three legs of a sandwich, in order, in one transaction.
/// @dev    Each leg names its own swapper in `hookData`, which the hook resolves through its
///         trusted-router path. Without that all three legs would resolve to this contract's
///         `tx.origin` and the middle leg would not read as a third party.
contract SandwichBundler {
    PoolSwapTest public immutable router;

    constructor(PoolSwapTest _router) {
        router = _router;
    }

    function approve(address token) external {
        MockERC20(token).approve(address(router), type(uint256).max);
    }

    function runSandwich(PoolKey memory key, address attacker, address victim, uint256 openSize, uint256 victimSize)
        external
    {
        _swap(key, attacker, true, openSize); // 1. attacker opens
        _swap(key, victim, true, victimSize); // 2. victim trades at the worse price
        _swap(key, attacker, false, openSize); // 3. attacker reverses out -> detected
    }

    function _swap(PoolKey memory key, address who, bool zeroForOne, uint256 amount) internal {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(who)
        );
    }
}
