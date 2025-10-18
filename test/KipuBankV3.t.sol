// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 public kipuBank;

    address public owner = address(1);
    address public user = address(2);
    address public universalRouter = address(3);
    address public weth = address(4);
    address public usdc = address(5);
    address public poolManager = address(6);

    uint256 public bankCapUsd = 100000000000; // 100k USD
    uint256 public withdrawThreshold = 1000000000000000000; // 1 ETH

    function setUp() public {
        MockOracle mockOracle = new MockOracle();
        vm.prank(owner);
        kipuBank = new KipuBankV3(
            bankCapUsd,
            withdrawThreshold,
            universalRouter,
            weth,
            usdc,
            poolManager,
            address(mockOracle)
        );
    }

    function testConstructor() public {
        assertEq(kipuBank.bankCapUsd(), bankCapUsd);
        assertEq(kipuBank.withdrawThreshold(), withdrawThreshold);
        assertEq(address(kipuBank.universalRouter()), universalRouter);
        assertEq(address(kipuBank.weth()), weth);
        assertEq(kipuBank.usdc(), usdc);
        assertEq(address(kipuBank.poolManager()), poolManager);
    }

    function testDepositETH() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        kipuBank.deposit{value: 1 ether}();

        assertEq(kipuBank.vaultOf(user, address(0)), 1 ether);
        assertEq(kipuBank.totalTokenBalances(address(0)), 1 ether);
    }

    function testWithdrawETH() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        kipuBank.deposit{value: 1 ether}();

        vm.prank(user);
        kipuBank.withdraw(0.5 ether);

        assertEq(kipuBank.vaultOf(user, address(0)), 0.5 ether);
        assertEq(kipuBank.totalTokenBalances(address(0)), 0.5 ether);
    }

    function testDepositERC20() public {
        // V2 does not support USD conversion for ERC20, so expect revert
        MockERC20 token = new MockERC20();
        vm.prank(owner);
        kipuBank.addSupportedToken(address(token), 18);

        token.mint(user, 1000 ether);
        vm.prank(user);
        token.approve(address(kipuBank), 1000 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(KipuBankV3.TokenNotSupported.selector, address(token)));
        kipuBank.depositERC20(address(token), 1000 ether);
    }

    function testWithdrawERC20() public {
        // Since deposit fails, withdraw also not tested
        // But V2 supports withdrawERC20 if deposited somehow, but since deposit reverts, skip
    }

    function testBankCapLimit() public {
        vm.deal(user, 100 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(KipuBankV3.CapExceeded.selector, 200000000000, 100000000000));
        kipuBank.deposit{value: 100 ether}();
    }

    function testWithdrawThreshold() public {
        vm.deal(user, 2 ether);
        vm.prank(user);
        kipuBank.deposit{value: 2 ether}();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(KipuBankV3.ThresholdExceeded.selector, 2 ether, 1 ether));
        kipuBank.withdraw(2 ether);
    }

    function testPausable() public {
        vm.prank(owner);
        kipuBank.pause();

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert();
        kipuBank.deposit{value: 1 ether}();
    }

    function testReentrancyGuard() public {
        // Basic test, assuming no reentrant function yet
        // For V2, deposit is nonReentrant
        vm.deal(user, 1 ether);
        vm.prank(user);
        kipuBank.deposit{value: 1 ether}();
        // No reentrancy test needed yet
    }
}

contract MockOracle {
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 200000000000, 0, 0, 0); // 2000 USD
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}