// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { EMA } from "./EMA.sol";
import { SD59x18 } from "@prb/math/src/SD59x18.sol";
import { AggregatorV3 } from "../interfaces/AggregatorV3.sol";

/**
 * @title VaultOracle - Exponential Moving Average (EMA) Oracle Contract
 * @author  KEOM Protocol
 * @dev An abstract contract that combines EMA functionality with external data feeds.
 */
abstract contract VaultOracle is EMA {
    address public underlyingToken;
    AggregatorV3 public underlyingDataFeed;

    /**
     * @dev Constructor to initialize the VaultOracle contract.
     * @param _underlyingToken The address of the underlying token.
     * @param _underlyingDataFeed The AggregatorV3 data feed for the underlying asset.
     * @param _span The span for EMA calculation.
     * @param _deviationThreshold The threshold for triggering an EMA update.
     * @param _maxDT The maximum period after which EMA should be updated.
     * @param _minDT The minimum period between consecutive EMA updates.
     */
    constructor(
        address _underlyingToken,
        AggregatorV3 _underlyingDataFeed,
        SD59x18 _span,
        uint256 _deviationThreshold,
        uint256 _maxDT, 
        uint256 _minDT
    ) EMA(_span, _deviationThreshold, _maxDT, _minDT) {
        underlyingToken = _underlyingToken;
        underlyingDataFeed = _underlyingDataFeed;
    }

    /**
     * @dev Function to update the exchange rate by calculating and setting the EMA value.
     */
    function updateExchangeRate() external {
        require(block.timestamp - lastUpdateTimestamp >= minDT, "VaultOracle: minimum dT not reached.");
        emit EMAExchangeRateUpdated(
            _EMA = _calculateEMA(getNewObs()),
            lastUpdateTimestamp = block.timestamp
        );
    }

    /**
     * @dev Function to retrieve the latest data from the data feed.
     * @return roundId The round ID of the latest data.
     * @return price The calculated price based on EMA or new observation.
     * @return startedAt The timestamp when the round started.
     * @return updatedAt The timestamp when the round was last updated.
     * @return answeredInRound The round in which the answer was recorded.
     */
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = underlyingDataFeed.latestRoundData();

        int256 price = int(
            (_EMA * uint(answer)) / 10 ** getUnderlyingDecimals()
        );

        uint256 updateTimestamp = updatedAt < lastUpdateTimestamp ? updatedAt : lastUpdateTimestamp;

        return (roundId, price, startedAt, updateTimestamp, answeredInRound);
    }

    /**
     * @dev Function to retrieve the number of decimal places in the underlying asset.
     * @return The number of decimal places.
     */
    function getUnderlyingDecimals() public view virtual returns (uint8);
}
