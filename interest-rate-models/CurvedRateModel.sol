//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./interfaces/IInterestRateModel.sol";

/**
 * @title 0VIX's JumpRateModel Contract
 * @author 0VIX
 */
contract CurvedRateModel is IInterestRateModel {
    bool public constant override isInterestRateModel = true;
    uint256 public constant timestampsPerYear = 31536000;
    /**
     * @notice borrow APR at Optimal utilization point (10%)
     */
    uint256 internal constant borrowAPRAtOptUtil = 0.1e18;
    /**
     * @notice optimal utilization point (80%)
     */
    uint256 internal constant optUtil = 0.8e18;
    /**
     * @notice borrow APR at 100% utilization (31,8%)
     */
    uint256 internal constant maxBorrowAPR = 0.318e18;

    /**
     * @notice The utilization point at which the curved multiplier is applied
     */
    uint256 internal constant kink = 0.6e18;

    uint256 internal constant paramA = 0.125e18; //  0.1/0.8
    uint256 internal constant paramB = 0.193e18; // 0.318 - (0.1 / 0.8)

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
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @return borrowAPR The borrow rate percentage per timestmp as a mantissa (scaled by 1e18)
     */
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public pure override returns (uint256 borrowAPR) {
        uint256 util = utilizationRate(cash, borrows, reserves);
        //Making utils to the power of 12 while taking decimals outa
        uint256 util12;
        if (util > kink) {
            //util^2
            util12 = (util * util) / 1e18;
            //util^4
            uint256 util4 = (util12 * util12) / 1e18;
            //util^8
            util12 = (util4 * util4) / 1e18;
            //util^12
            util12 = (util12 * util4) / 1e18;
        }
        borrowAPR = (util * (paramA + ((paramB * util12) / 1e18))) / 1e18;
        borrowAPR /= timestampsPerYear;
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
    ) public pure override returns (uint256 supplyRate) {
        uint256 oneMinusReserveFactor = uint256(1e18) - reserveFactorMantissa;
        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);
        uint256 rateToPool = (borrowRate * oneMinusReserveFactor) / 1e18;
        supplyRate =
            (utilizationRate(cash, borrows, reserves) * rateToPool) /
            1e18;
    }
}
