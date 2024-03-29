//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./IEIP20NonStandard.sol";
import "./IKToken.sol";

interface IKErc20 {

    /*** User Interface ***/

    function mint(uint mintAmount) external;
    function redeem(uint redeemTokens) external;
    function redeemUnderlying(uint redeemAmount) external;
    function borrow(uint borrowAmount) external;
    function repayBorrow(uint repayAmount) external;
    function repayBorrowBehalf(address borrower, uint repayAmount) external;
    function liquidateBorrow(address borrower, uint repayAmount, IKToken kTokenCollateral) external;

    function underlying() external view returns(address);

    /*** Admin Functions ***/

    function _addReserves(uint addAmount) external returns (uint);
}
