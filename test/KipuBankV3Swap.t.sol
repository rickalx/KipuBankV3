// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";

contract KipuBankV3SwapTest is Test {
    KipuBankV3 public kipuBank;

    address public owner = address(1);
    address public universalRouter = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address public weth = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public usdc = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;
    address public poolManager = 0x1D93eFBDa2A6FE18c8FcFf65B3F9Bc96bCCA1af2;
    address public permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 public bankCapUsd = 100000000000;
    uint256 public withdrawThreshold = 1000000000000000000;

    function setUp() public {
        vm.createSelectFork("https://sepolia.infura.io/v3/YOUR_INFURA_KEY"); // Replace with actual key
        vm.prank(owner);
        kipuBank = new KipuBankV3(
            bankCapUsd,
            withdrawThreshold,
            universalRouter,
            weth,
            usdc,
            poolManager,
            permit2,
            0x694AA1769357215DE4FAC081bf1f309aDC325306 // oracle
        );
    }

    function testSetPoolFee() public {
        vm.prank(owner);
        kipuBank.setPoolFee(address(0), 500);
        assertEq(kipuBank.poolFees(address(0)), 500);
    }

    function testGetPoolFeeWithDefault() public {
        assertEq(kipuBank.getPoolFee(address(0)), 3000); // DEFAULT_POOL_FEE
        vm.prank(owner);
        kipuBank.setPoolFee(address(0), 500);
        assertEq(kipuBank.getPoolFee(address(0)), 500);
    }

    function testCalculateMinAmount() public {
        // Test internal function, but since private, can't call directly
        // Perhaps add a public wrapper for testing
    }

    // Note: Actual swap tests require real liquidity and funds, so these are placeholders
    function testSwapWETHToUSDC() public {
        // Placeholder
        // vm.deal(address(kipuBank), 1 ether);
        // uint256 amountOut = kipuBank._swapExactInputSingle(address(0), usdc, 1 ether, 0);
        // assertGt(amountOut, 0);
    }

    function testSwapDAIToUSDC() public {
        // Placeholder
    }

    function testSwapInsufficientLiquidity() public {
        // Placeholder
    }

    function testSwapSlippageExceeded() public {
        // Placeholder
    }

    function testSwapZeroAmount() public {
        // Placeholder
    }

    function testSwapInvalidPoolFee() public {
        // Placeholder
    }
}
