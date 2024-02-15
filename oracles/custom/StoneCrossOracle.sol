// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { IStoneCross } from "../../interfaces/IStoneCross.sol";
import { VaultOraclePyth, IPyth, SD59x18 } from "./abstract/VaultOraclePyth.sol";

/**
 * @title StoneCrossOracle - Stone Cross Oracle
 * @author KEOM Protocol
 * @dev An EMA-based Oracle contract for the Stone Cross market.
 */
contract StoneCrossOracle is VaultOraclePyth {
    constructor(
        address _underlyingToken,
        IPyth _pyth,
        bytes32 _tokenId,
        SD59x18 _span,
        uint256 _deviationThreshold,
        uint256 _maxDT,
        uint256 _minDT
    )
        VaultOraclePyth(
            _underlyingToken,
            _pyth,
            _tokenId,
            _span,
            _deviationThreshold,
            _maxDT,
            _minDT
        )
    {}

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function description() external pure returns (string memory) {
        return "KEOM Stone Cross Oracle";
    }

    function getNewObs() public view override returns (uint256) {
        return IStoneCross(underlyingToken).tokenPrice();
    }

    function getUnderlyingDecimals() public view override returns (uint8) {
        return IStoneCross(underlyingToken).decimals();
    }
}
