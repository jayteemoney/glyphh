// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {IReputationRegistry} from "../src/interfaces/IReputationRegistry.sol";

/// @notice ScoreWallet — sign + submit one EIP-712 score attestation, the same way the
/// off-chain detector (ai/detector) would. Handy for demos and manual testing: it lets you
/// flag a wallet on a running chain without standing up the Python detector.
///
/// The signer key (DEPLOYER_PRIVATE_KEY) must be an authorized attestor on the registry.
///
/// Run:
///   DEPLOYER_PRIVATE_KEY=0x... REGISTRY_ADDRESS=0x... WALLET=0x... SCORE=8000 \
///   forge script script/ScoreWallet.s.sol --rpc-url "$RPC_URL" --broadcast
contract ScoreWallet is Script {
    function run() external {
        uint256 attestorKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        ReputationRegistry registry = ReputationRegistry(vm.envAddress("REGISTRY_ADDRESS"));
        address wallet = vm.envAddress("WALLET");
        uint16 score = uint16(vm.envOr("SCORE", uint256(8000)));

        // Next nonce must be strictly greater than the last one used for this wallet.
        IReputationRegistry.Score memory sd = registry.scoreDataOf(wallet);
        uint32 nonce = sd.nonce + 1;
        uint64 deadline = uint64(block.timestamp + 600);

        // Build the EIP-712 digest exactly as the registry verifies it.
        bytes32 structHash = keccak256(abi.encode(registry.SCORE_TYPEHASH(), wallet, score, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", registry.domainSeparator(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorKey, digest);

        IReputationRegistry.Attestation memory a = IReputationRegistry.Attestation({
            wallet: wallet,
            value: score,
            nonce: nonce,
            deadline: deadline,
            signature: abi.encodePacked(r, s, v)
        });

        vm.broadcast(attestorKey);
        registry.updateScore(a);

        console2.log("Scored wallet:", wallet);
        console2.log("  value:", score);
        console2.log("  nonce:", nonce);
        console2.log("  on-chain scoreOf:", registry.scoreOf(wallet));
    }
}
