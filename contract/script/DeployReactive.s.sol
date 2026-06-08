// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {GlyphReactive} from "../src/reactive/GlyphReactive.sol";

/// @notice Deploys the GlyphReactive RSC on the Reactive Network (Kopli).
/// @dev    Run AFTER DeployGlyph.s.sol, which deploys ReputationRegistry + GlyphCallbackAdapter
///         on the origin chain. Then fund the deployed RSC with REACT so it can pay for callbacks,
///         and (optionally) call `adapter.setRvmId(<rvmId>)` to pin the RVM id.
contract DeployReactive is Script {
    uint256 constant DEFAULT_ORIGIN_CHAIN_ID = 1301; // Unichain Sepolia
    uint256 constant DEFAULT_DEST_CHAIN_ID = 1301; // callback lands back on the registry chain

    function run() external {
        uint256 deployerKey = vm.envUint("REACTIVE_PRIVATE_KEY");
        address registry = vm.envAddress("REGISTRY_ADDRESS");
        address adapter = vm.envAddress("CALLBACK_ADAPTER_ADDRESS");
        uint256 originChain = vm.envOr("ORIGIN_CHAIN_ID", DEFAULT_ORIGIN_CHAIN_ID);
        uint256 destChain = vm.envOr("DEST_CHAIN_ID", DEFAULT_DEST_CHAIN_ID);

        console2.log("Origin chain:", originChain);
        console2.log("Dest chain:  ", destChain);
        console2.log("Registry:    ", registry);
        console2.log("Adapter:     ", adapter);

        vm.startBroadcast(deployerKey);
        GlyphReactive reactive = new GlyphReactive(originChain, destChain, registry, adapter);
        vm.stopBroadcast();

        console2.log("---");
        console2.log("GlyphReactive (RSC):", address(reactive));
        console2.log("Fund the RSC with REACT so it can pay for cross-pool callbacks.");
    }
}
