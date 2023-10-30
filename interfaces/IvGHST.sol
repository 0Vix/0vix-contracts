// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IvGHST {
    function convertVGHST(uint256 _share) external view returns(uint256 _ghst);
    function decimals() external view returns(uint8);
}