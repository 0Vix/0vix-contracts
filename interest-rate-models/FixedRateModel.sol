//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./interfaces/IInterestRateModel.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title KEOM's FixedRateModel Contract
 * @author KEOM
 */
contract FixedRateModel is IInterestRateModel, Ownable {
    bool public constant override isInterestRateModel = true;
    uint256 public constant timestampsPerYear = 31536000;
    uint256 private borrowRate;

    constructor(uint256 _borrowRate) {
        borrowRate = _borrowRate;
    }

    /**
     * @notice Sets annual borrow iterest rate
     * @param _borrowRate Annual borrow rate that will be set
     */
    function setBorrowRate(uint256 _borrowRate) 
        external onlyOwner 
    {
        borrowRate = _borrowRate;
    }

    /**
     * @notice Calculates the utilization rate of the market: `borrows / (cash + borrows - reserves)`
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market (currently unused)
     * @return The utilization rate as a mantissa between [0, 1e18]
     */
    function utilizationRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public pure returns (uint256) {
        // Utilization rate is 0 when there are no borrows
        if (borrows == 0) {
            return 0;
        }

        return (borrows * 1e18) / (cash + borrows - reserves);
    }

    /**
     * @notice Calculates the current borrow rate per timestmp, with the error code expected by the market
     * @return borrowAPR The borrow rate percentage per timestmp as a mantissa (scaled by 1e18)
     */
    function getBorrowRate(
        uint256,
        uint256,
        uint256
    ) public view override returns (uint256 borrowAPR) {
        borrowAPR = borrowRate / timestampsPerYear;
    }

    /**
     * @notice Calculates the current supply rate per timestmp
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @param reserveFactorMantissa The current reserve factor for the market
     * @return supplyRate The supply rate percentage per timestmp as a mantissa (scaled by 1e18)
     */
    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa
    ) public view override returns (uint256 supplyRate) {
        uint256 oneMinusReserveFactor = uint256(1e18) - reserveFactorMantissa;
        uint256 borrowAPR = getBorrowRate(cash, borrows, reserves);
        uint256 rateToPool = (borrowAPR * oneMinusReserveFactor) / 1e18;
        supplyRate =
            (utilizationRate(cash, borrows, reserves) * rateToPool) /
            1e18;
    }
}