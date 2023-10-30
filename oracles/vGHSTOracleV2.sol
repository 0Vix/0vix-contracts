// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { IvGHST } from "../interfaces/IvGHST.sol";
import { VaultOracle, AggregatorV3, SD59x18 } from "./abstract/VaultOracle.sol";

/**
 * @title VGHSTOracleV2 - vGHST Oracle Version 2
 * @author KEOM Protocol
 * @dev An EMA-based Oracle contract for the vGHST market.
 */
contract VGHSTOracleV2 is VaultOracle {
    constructor(
        address _underlyingToken,
        AggregatorV3 _underlyingDataFeed,
        SD59x18 _span,
        uint256 _deviationThreshold,
        uint256 _maxDT,
        uint256 _minDT
    )
        VaultOracle(
            _underlyingToken,
            _underlyingDataFeed,
            _span,
            _deviationThreshold,
            _maxDT,
            _minDT
        )
    {}

    function decimals() external view returns (uint8) {
        return underlyingDataFeed.decimals();
    }

    function version() external view returns (uint256) {
        return underlyingDataFeed.version();
    }

    function description() external pure returns (string memory) {
        return "KEOM vGHST Oracle V2";
    }

    function getNewObs() public view override returns (uint256) {
        return IvGHST(underlyingToken).convertVGHST(1 ether);
    }

    function getUnderlyingDecimals() public view override returns (uint8) {
        return IvGHST(underlyingToken).decimals();
    }
}
