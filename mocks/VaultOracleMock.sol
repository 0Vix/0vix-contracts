// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { EMA, SD59x18, sd, convert } from "../oracles/abstract/EMA.sol";
import "hardhat/console.sol";

contract VaulOracleMock is EMA {
    uint256 private mockNewObs;
    int256 private answer;
    uint8 private mockUnderlyingDecimals = 18;

    constructor(
        SD59x18 _span,
        uint256 _deviationThreshold,
        uint256 _maxDT, uint256 _minDT
    ) EMA(_span, _deviationThreshold, _maxDT,_minDT) {
        // lastUpdateTimestamp = block.timestamp;
    }

    function updateExchangeRate() external {
        emit EMAExchangeRateUpdated(
            _EMA = _calculateEMA(getNewObs()),
            lastUpdateTimestamp = block.timestamp
        );
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (
            uint80 roundId,
            int256 _answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = mockUnderlyingDataFeed();

        int256 price = int(
            (_EMA * uint(_answer)) / 10 ** getUnderlyingDecimals()
        );

        return (roundId, price, startedAt, updatedAt, answeredInRound);
    }

    function setNewObs(uint256 newObs) public {
        mockNewObs = newObs;
    }

    function setAnswer(int256 _answer) public {
        answer = _answer;
    }

    function getNewObs() public view override returns (uint256) {
        return mockNewObs;
    }

    function calculateDeviationMock() public view returns (uint256 deviation) {
        return _calculateDeviation();
    }

    function getUnderlyingDecimals() public view returns (uint8) {
        return mockUnderlyingDecimals;
    }

    event CEXP(
        SD59x18 dT,
        SD59x18 span,
        SD59x18 expDiv,
        SD59x18 exp,
        uint256 uExp
    );

    function calcEXP() public returns (SD59x18 exp, uint256 uExp) {
        SD59x18 dT = sd(-1 * int256(block.timestamp - lastUpdateTimestamp));
        SD59x18 expDiv = (dT.div(span));
        exp = dT.div(span).exp2();
        uExp = uint256(SD59x18.unwrap(exp));
        lastUpdateTimestamp = block.timestamp;
        emit CEXP(dT, span, expDiv, exp, uExp);
    }

    function mockUnderlyingDataFeed()
        public
        view
        returns (
            uint80 roundId,
            int256 _awnser,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId;
        _awnser = answer;
        startedAt;
        updatedAt;
        answeredInRound;
    }
}
