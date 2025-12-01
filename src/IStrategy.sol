// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategy {
    function totalValue() external view returns (uint256);

    function invest(uint256 assets) external;

    function withdraw(uint256 assets) external;
}
