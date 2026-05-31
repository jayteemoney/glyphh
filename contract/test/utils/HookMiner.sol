// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Utility: mines a CREATE2 salt so that the deployed hook address's
///         14 low bits match the required Uniswap v4 permission flags.
///
/// Usage:
///   (address hookAddress, bytes32 salt) = HookMiner.find(deployer, flags, creationCode, args);
///
/// This is shared between P1 (deploy script) and tests. Do not add business logic here.
library HookMiner {
    uint160 constant FLAG_MASK = 0x3FFF; // 14 bits

    /// @notice Mine a salt such that `CREATE2(deployer, salt, creationCode)` produces
    ///         an address whose lower 14 bits equal `flags`.
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 bytecodeHash  = keccak256(bytecode);

        for (uint256 i = 0; i < type(uint256).max; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, bytecodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags & FLAG_MASK) {
                return (hookAddress, salt);
            }
        }
        revert("HookMiner: no salt found");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 bytecodeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(hex"ff", deployer, salt, bytecodeHash))
                )
            )
        );
    }
}
