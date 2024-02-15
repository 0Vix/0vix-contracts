// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IStoneCross {
    function tokenPrice() external view returns (uint256);
    function decimals() external view returns(uint8);
}