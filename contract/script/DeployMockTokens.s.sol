// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract DeployMockTokens is Script {
    uint256 constant INITIAL_SUPPLY = 1_000_000 * 1e18;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockERC20 tokenA = new MockERC20("Glyph Token A", "GLYPH-A", 18);
        MockERC20 tokenB = new MockERC20("Glyph Token B", "GLYPH-B", 18);

        tokenA.mint(deployer, INITIAL_SUPPLY);
        tokenB.mint(deployer, INITIAL_SUPPLY);

        vm.stopBroadcast();

        console2.log("MockERC20 GLYPH-A:", address(tokenA));
        console2.log("MockERC20 GLYPH-B:", address(tokenB));
        console2.log("Minted", INITIAL_SUPPLY / 1e18, "tokens each to", deployer);
        console2.log("---");
        console2.log("Copy these into your .env:");
        console2.log("TOKEN_A=", address(tokenA));
        console2.log("TOKEN_B=", address(tokenB));
    }
}
