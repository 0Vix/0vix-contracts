// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { EMA } from "./EMA.sol";
import { SD59x18 } from "@prb/math/src/SD59x18.sol";
import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs } from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VaultOraclePyth - Exponential Moving Average (EMA) Oracle Contract
 * @author  KEOM Protocol
 * @dev An abstract contract that combines EMA functionality with external data feeds.
 */
abstract contract VaultOraclePyth is EMA, Ownable {
    address public underlyingToken;
    IPyth public pyth;
    bytes32 public tokenId;

    /**
     * @dev Constructor to initialize the VaultOraclePyth contract.
     * @param _underlyingToken The address of the underlying token.
     * @param _pyth The pyth oracle address.
     * @param _tokenId The pyth token id.
     * @param _span The span for EMA calculation.
     * @param _deviationThreshold The threshold for triggering an EMA update.
     * @param _maxDT The maximum period after which EMA should be updated.
     * @param _minDT The minimum period between consecutive EMA updates.
     */
    constructor(
        address _underlyingToken,
        IPyth _pyth,
        bytes32 _tokenId,
        SD59x18 _span,
        uint256 _deviationThreshold,
        uint256 _maxDT, 
        uint256 _minDT
    ) EMA(_span, _deviationThreshold, _maxDT, _minDT) {
        underlyingToken = _underlyingToken;
        pyth = _pyth;
        tokenId = _tokenId;
    }

    /**
     * @dev Function to update the exchange rate by calculating and setting the EMA value.
     */
    function updateExchangeRate() external onlyOwner {
        require(block.timestamp - lastUpdateTimestamp >= minDT, "VaultOracle: minimum dT not reached.");
        emit EMAExchangeRateUpdated(
            _EMA = _calculateEMA(getNewObs()),
            lastUpdateTimestamp = block.timestamp
        );
    }


   function latestRoundData()
        external
        view
        returns (uint80 roundId, int256, uint256 startedAt, uint256 updateAt, uint80 answeredInRound)
    {
        PythStructs.Price memory priceData = pyth.getPriceUnsafe(tokenId);

        int256 price = int(
            (_EMA * uint256(int256(priceData.price))) / 10 ** getUnderlyingDecimals()
        );

        updateAt = priceData.publishTime < lastUpdateTimestamp ? priceData.publishTime : lastUpdateTimestamp;

        return (roundId, price, startedAt, updateAt, answeredInRound);
    }

    /**
     * @dev Function to retrieve the number of decimal places in the underlying asset.
     * @return The number of decimal places.
     */
    function getUnderlyingDecimals() public view virtual returns (uint8);
}
