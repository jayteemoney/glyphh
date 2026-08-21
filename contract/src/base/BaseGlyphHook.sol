// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

/// @title  BaseGlyphHook
/// @notice Minimal `IHooks` base: reverting defaults for every callback, one virtual
///         permissions declaration, and address validation at construction.
///
/// @dev    Two reasons this exists rather than being inlined into GlyphHook.
///
///         First, correctness. v4 derives a hook's permissions from the low bits of its
///         *address*, while `getHookPermissions` is just a function the author writes. Nothing
///         forces them to agree. Validating in the constructor makes a mismatch a failed
///         deployment instead of a hook that silently never fires the callback you thought you
///         had enabled — the classic v4 footgun, and one that costs an afternoon to diagnose.
///
///         Second, honesty about the surface. v1 implemented all ten callbacks as no-op stubs
///         returning their selectors. That is worse than not implementing them: a stub is
///         indistinguishable from a real implementation to anyone reading the interface, and
///         if a permission bit were ever set by accident the stub would quietly accept the
///         call. Reverting defaults mean an unpermissioned callback that somehow gets invoked
///         fails loudly.
///
///         v4-periphery ships no `BaseHook` at our pinned commit, so this is vendored rather
///         than imported. Bumping the submodule mid-hookathon is not a trade worth making.
abstract contract BaseGlyphHook is IHooks, ImmutableState {
    error HookNotImplemented();

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Which callbacks this hook implements. Must match the deployed address's low bits.
    function getHookPermissions() public pure virtual returns (Hooks.Permissions memory);

    // ── Defaults: revert unless overridden ───────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
