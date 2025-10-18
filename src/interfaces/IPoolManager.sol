// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@uniswap/v4-core/src/types/Currency.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";

interface IPoolManager {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96, bytes calldata hookData) external;
    // Other functions as needed
}