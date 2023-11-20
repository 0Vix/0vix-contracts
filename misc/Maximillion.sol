//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../ktokens/KNative.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title KEOM's Maximillion Contract
 * @author KEOM
 */
contract Maximillion {
    /**
     * @notice The default kNative market to repay in
     */
    KNative public immutable kNative;

    /**
     * @notice Construct a Maximillion to repay max in a KNative market
     */
    constructor(KNative kNative_) {
        kNative = kNative_;
    }

    /**
     * @notice msg.sender sends Native to repay an account's borrow in the kNative market
     * @dev The provided Native is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, kNative);
    }

    /**
     * @notice msg.sender sends Native to repay an account's borrow in a kNative market
     * @dev The provided Native is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param cNative_ The address of the kNative contract to repay in
     */
    function repayBehalfExplicit(address borrower, KNative cNative_) public payable {
        uint received = msg.value;
        uint borrows = cNative_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            cNative_.repayBorrowBehalf{value: borrows}(borrower);
            Address.sendValue(payable(msg.sender), received - borrows);
        } else {
            cNative_.repayBorrowBehalf{value: received}(borrower);
        }
    }
}
