// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SD59x18, sd, convert } from "@prb/math/src/SD59x18.sol";

/**
 * @title EMA - Exponential Moving Average (EMA) Contract
 * @author  KEOM Protocol
 * @dev An abstract contract for calculating and updating Exponential Moving Averages.
 */
abstract contract EMA {
    uint256 public _EMA;
    uint256 public lastUpdateTimestamp;
    uint256 public D;
    SD59x18 public span;
    uint256 public deviationThreshold;
    uint256 public maxDT;
    uint256 public minDT;
    uint256 public constant PRECISION = 1e18;

    /**
     * @dev Emitted when the EMA exchange rate is updated.
     * @param _EMA The new EMA exchange rate.
     * @param _timestamp The timestamp of the update.
     */
    event EMAExchangeRateUpdated(uint256 _EMA, uint256 _timestamp);

    /**
     * @dev Constructor to initialize the EMA contract.
     * @param _span The span for EMA calculation.
     * @param _deviationThreshold The threshold for triggering an EMA update.
     * @param _maxDT The maximum period after which EMA should be updated.
     * @param _minDT The minimum period between consecutive EMA updates.
     */
    constructor(
        SD59x18 _span,
        uint256 _deviationThreshold,
        uint256 _maxDT,
        uint256 _minDT
    ) {
        span = _span;
        deviationThreshold = _deviationThreshold;
        maxDT = _maxDT;
        minDT = _minDT;
    }

    /**
     * @dev Function to get the new observation value.
     * @return The new observation value.
     */
    function getNewObs() public view virtual returns (uint256);

    /**
     * @dev Function to determine if an EMA update is necessary.
     * @return updateNecessary True if an update is required, false otherwise.
     */
    function shouldUpdateEMA() external view returns (bool updateNecessary) {
        if (block.timestamp - lastUpdateTimestamp < minDT) {
            return false;
        }
        uint256 deviation = _calculateDeviation();
        updateNecessary =
            block.timestamp - lastUpdateTimestamp >= maxDT ||
            deviation >= deviationThreshold;
    }

    /**
     * @dev Internal function to calculate the EMA.
     * @param newObs The new observation value.
     * @return ema The calculated EMA.
     */
    function _calculateEMA(uint256 newObs) internal returns (uint256 ema) {
        SD59x18 dT = sd(-1 * int256(block.timestamp - lastUpdateTimestamp));
        SD59x18 exp = dT.div(span).exp2();
        D = ((D + PRECISION) * uint256(SD59x18.unwrap(exp))) / PRECISION;
        ema = ((newObs * PRECISION) + (D * _EMA)) / (D + PRECISION);
    }

    /**
     * @dev Internal function to calculate the deviation.
     * @return deviation The calculated deviation.
     */
    function _calculateDeviation() internal view returns (uint256 deviation) {
        if (_EMA == 0) {
            return deviationThreshold;
        }
        uint256 newObs = getNewObs();
        uint256 numerator = newObs > _EMA
            ? PRECISION * (newObs - _EMA)
            : PRECISION * (_EMA - newObs);
        deviation = (numerator / _EMA);
    }
}
