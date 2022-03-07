pragma solidity 0.8.4;

import "./IEIP20NonStandard.sol";
import "./IOToken.sol";

interface IOErc20 {

    /*** User Interface ***/

    function mint(uint mintAmount) external returns (uint);
    function redeem(uint redeemTokens) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function borrow(uint borrowAmount) external returns (uint);
    function repayBorrow(uint repayAmount) external returns (uint);
    function repayBorrowBehalf(address borrower, uint repayAmount) external returns (uint);
    function liquidateBorrow(address borrower, uint repayAmount, IOToken oTokenCollateral) external returns (uint);
    function sweepToken(IEIP20NonStandard token) external;


    /*** Admin Functions ***/

    function _addReserves(uint addAmount) external returns (uint);
}
