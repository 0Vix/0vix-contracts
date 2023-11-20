//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IKTokenTemp {
    /*** temp Functions ***/
    function _burnOTokensFromKTokens(address[] calldata accounts, uint256 totalBurned) external;
}
