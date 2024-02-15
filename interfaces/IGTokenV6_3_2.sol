// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IGTokenV6_3_2 {
    function shareToAssetsPrice() external view returns (uint256);
    function decimals() external view returns(uint8);
}