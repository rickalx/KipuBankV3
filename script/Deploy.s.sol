// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/KipuBankV3.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Constructor parameters - update with actual addresses
        uint256 bankCapUsd = 100000000000; // 100k USD
        uint256 withdrawThreshold = 1000000000000000000; // 1 ETH
        address universalRouter = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD; // Sepolia
        address weth = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // Sepolia
        address usdc = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // Sepolia
        address poolManager = 0x1D93eFBDa2A6FE18c8FcFf65B3F9Bc96bCCA1af2; // Sepolia
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Sepolia
        address dataFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia ETH/USD

        KipuBankV3 kipuBank = new KipuBankV3(
            bankCapUsd,
            withdrawThreshold,
            universalRouter,
            weth,
            usdc,
            poolManager,
            permit2,
            dataFeed
        );

        vm.stopBroadcast();

        console.log("KipuBankV3 deployed at:", address(kipuBank));
    }
}