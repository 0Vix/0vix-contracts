//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../ktokens/interfaces/IKToken.sol";
import "../oracles/PriceOracle.sol";

interface IComptroller {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    function isComptroller() external view returns(bool);

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata kTokens) external returns (uint[] memory);
    function exitMarket(address kToken) external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address kToken, address minter, uint mintAmount) external returns (uint);

    function redeemAllowed(address kToken, address redeemer, uint redeemTokens) external returns (uint);
    function redeemVerify(address kToken, address redeemer, uint redeemAmount, uint redeemTokens) external;

    function borrowAllowed(address kToken, address borrower, uint borrowAmount) external returns (uint);

    function repayBorrowAllowed(
        address kToken,
        address payer,
        address borrower,
        uint repayAmount) external returns (uint);

    function liquidateBorrowAllowed(
        address kTokenBorrowed,
        address kTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) external returns (uint, uint);

    function seizeAllowed(
        address kTokenCollateral,
        address kTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external returns (uint);

    function transferAllowed(address kToken, address src, address dst, uint transferTokens) external returns (uint);

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address kTokenBorrowed,
        address kTokenCollateral,
        uint repayAmount,
        uint dynamicLiquidationIncentive) external view returns (uint, uint);

    function isMarket(address market) external view returns(bool);
    function getAllMarkets() external view returns(IKToken[] memory);
    function oracle() external view returns(PriceOracle);
    function updatePrices(bytes[] calldata priceUpdateData) external;
}
