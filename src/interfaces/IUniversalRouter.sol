// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

enum Commands {
    V3_SWAP_EXACT_IN,
    V3_SWAP_EXACT_OUT,
    PERMIT2_TRANSFER_FROM,
    PERMIT2_PERMIT_BATCH,
    V4_SWAP,
    V3_SWAP_EXACT_IN_SINGLE,
    V3_SWAP_EXACT_OUT_SINGLE,
    WRAP_ETH,
    UNWRAP_WETH,
    PERMIT2_PERMIT,
    TRANSFER,
    V4_SWAP_SINGLE
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
