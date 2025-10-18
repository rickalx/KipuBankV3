// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}