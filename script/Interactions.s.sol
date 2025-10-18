// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/KipuBankV3.sol";

contract InteractionsScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address payable kipuBankAddress = payable(vm.envAddress("KIPU_BANK_ADDRESS")); // Set env var
        KipuBankV3 kipuBank = KipuBankV3(kipuBankAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Example interactions
        // Add a supported token
        kipuBank.addSupportedToken(0xA0B86A33e6441e88C5f2712C3e9b74Ec6f6E8F0d, 18); // Example token

        // Set pool fee for ETH
        kipuBank.setPoolFee(address(0), 500); // 0.05%

        // Deposit ETH
        kipuBank.deposit{value: 0.1 ether}();

        vm.stopBroadcast();
    }
}