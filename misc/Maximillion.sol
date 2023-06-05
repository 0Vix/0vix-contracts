//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../otokens/ONative.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title 0VIX's Maximillion Contract
 * @author 0VIX
 */
contract Maximillion {
    /**
     * @notice The default oNative market to repay in
     */
    ONative public immutable oNative;

    /**
     * @notice Construct a Maximillion to repay max in a ONative market
     */
    constructor(ONative oNative_) {
        oNative = oNative_;
    }

    /**
     * @notice msg.sender sends Native to repay an account's borrow in the oNative market
     * @dev The provided Native is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, oNative);
    }

    /**
     * @notice msg.sender sends Native to repay an account's borrow in a oNative market
     * @dev The provided Native is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param oNative_ The address of the oNative contract to repay in
     */
    function repayBehalfExplicit(address borrower, ONative oNative_) public payable {
        uint received = msg.value;
        uint borrows = oNative_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            oNative_.repayBorrowBehalf{value: borrows}(borrower);
            Address.sendValue(payable(msg.sender), received - borrows);
        } else {
            oNative_.repayBorrowBehalf{value: received}(borrower);
        }
    }
}
