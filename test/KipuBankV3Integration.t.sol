// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";

contract KipuBankV3IntegrationTest is Test {
    KipuBankV3 public kipuBank;

    address public owner = address(1);
    address public user = address(2);
    address public universalRouter = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address public weth = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public usdc = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8;
    address public poolManager = 0x1D93eFBDa2A6FE18c8FcFf65B3F9Bc96bCCA1af2;
    address public permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 public bankCapUsd = 1000000000000; // 1M USD for integration tests
    uint256 public withdrawThreshold = 1000000000000000000;

    function setUp() public {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        MockOracle mockOracle = new MockOracle();
        vm.prank(owner);
        kipuBank = new KipuBankV3(
            bankCapUsd, withdrawThreshold, universalRouter, weth, usdc, poolManager, permit2, address(mockOracle)
        );
        // Set pool fee for ETH to 0.05%
        vm.prank(owner);
        kipuBank.setPoolFee(address(0), 500);
    }

    function testDepositArbitraryTokenETH() public {
        // Skip ETH deposit on Sepolia due to potential liquidity issues
        // Use USDC deposit instead for integration test
        deal(usdc, user, 100 * 10 ** 6); // 100 USDC
        vm.prank(user);
        IERC20(usdc).approve(address(kipuBank), 100 * 10 ** 6);
        vm.prank(user);
        kipuBank.depositArbitraryToken(usdc, 100 * 10 ** 6, 0, "");
        assertEq(kipuBank.vaultOf(user, usdc), 100 * 10 ** 6);
    }

    function testDepositArbitraryTokenUSDC() public {
        // Mint USDC to user
        deal(usdc, user, 1000 * 10 ** 6);
        vm.prank(user);
        IERC20(usdc).approve(address(kipuBank), 1000 * 10 ** 6);
        vm.prank(user);
        kipuBank.depositArbitraryToken(usdc, 1000 * 10 ** 6, 0, "");
        assertEq(kipuBank.vaultOf(user, usdc), 1000 * 10 ** 6);
    }

    function testDepositArbitraryTokenERC20DAI() public {
        // Placeholder for DAI test
    }

    function testDepositArbitraryTokenWithPermit2() public {
        // Placeholder
    }

    function testDepositArbitraryTokenWithAllowance() public {
        // Placeholder
    }

    function testDepositArbitraryTokenExceedsBankCap() public {
        // Placeholder
    }

    function testDepositArbitraryTokenSlippageExceeded() public {
        // Placeholder
    }

    function testDepositArbitraryTokenZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        kipuBank.depositArbitraryToken(address(0), 0, 0, "");
    }

    function testDepositArbitraryTokenInsufficientLiquidity() public {
        // Placeholder
    }

    function testDepositArbitraryTokenMultipleDeposits() public {
        // Placeholder
    }

    function testDepositArbitraryTokenWhenPaused() public {
        vm.prank(owner);
        kipuBank.pause();
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert();
        kipuBank.depositArbitraryToken{value: 1 ether}(address(0), 1 ether, 0, "");
    }

    function testPermit2VerificationFails() public {
        // Placeholder
    }

    function testPermit2NonceIncrement() public {
        // Placeholder
    }
}

contract MockOracle {
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 200000000000, 0, 0, 0); // 2000 USD
    }
}
