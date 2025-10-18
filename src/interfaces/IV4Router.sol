// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

enum Actions {
    SWAP_EXACT_IN_SINGLE,
    SWAP_EXACT_IN,
    SWAP_EXACT_OUT_SINGLE,
    SWAP_EXACT_OUT,
    SETTLE_ALL,
    TAKE_ALL,
    SETTLE,
    TAKE,
    TAKE_PORTION,
    SETTLE_PAIR
}

interface IV4Router {
    function execute(Actions[] calldata actions, bytes[] calldata params) external payable;
}