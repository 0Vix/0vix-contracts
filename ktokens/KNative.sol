//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./abstract/KToken.sol";

/**
 * @title KEOM's KNative Contract
 * @notice KToken which wraps Native
 * @author KEOM
 */
contract KNative is KToken {
    /**
     * @notice Construct a new KNative money market
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     * @param admin_ Address of the administrator of this token
     */

    function initialize(
        IComptroller comptroller_,
        IInterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_
    ) external initializer {
        admin = payable(msg.sender);

        super.initialize(
            comptroller_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_
        );

        // Set the proper admin now that initialization is done
        admin = admin_;
    }

    /*** User Interface ***/

    /**
     * @notice Sender supplies assets into the market and receives kTokens in exchange
     * @dev Reverts upon any failure
     */
    function mint() external payable {
        (uint256 err, ) = mintInternal(msg.value);
        requireNoError(err, "mint failed");
    }

    /**
     * @notice Sender redeems kTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of kTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(uint256 redeemTokens) external returns (uint256) {
        return redeemInternal(redeemTokens);
    }

    /**
     * @notice Sender redeems kTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to redeem
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        return redeemUnderlyingInternal(redeemAmount);
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param borrowAmount The amount of the underlying asset to borrow
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function borrow(uint256 borrowAmount) external returns (uint256) {
        return borrowInternal(borrowAmount);
    }

    /**
     * @notice Sender repays their own borrow
     * @dev Reverts upon any failure
     */
    function repayBorrow() external payable {
        (uint256 err, ) = repayBorrowInternal(msg.value);
        requireNoError(err, "repayBorrow failed");
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @dev Reverts upon any failure
     * @param borrower the account with the debt being payed off
     */
    function repayBorrowBehalf(address borrower) external payable {
        (uint256 err, ) = repayBorrowBehalfInternal(borrower, msg.value);
        requireNoError(err, "repayBorrowBehalf failed");
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @dev Reverts upon any failure
     * @param borrower The borrower of this kToken to be liquidated
     * @param kTokenCollateral The market in which to seize collateral from the borrower
     */
    function liquidateBorrow(address borrower, IKToken kTokenCollateral)
        external
        payable
    {
        (uint256 err, ) = liquidateBorrowInternal(
            borrower,
            msg.value,
            kTokenCollateral
        );
        requireNoError(err, "liquidateBorrow failed");
    }

    /**
     * @notice The sender liquidates the borrowers collateral and updates prices at Pyth's oracle.
     *  The collateral seized is transferred to the liquidator.
     * @dev Reverts upon any failure
     * @param borrower The borrower of this kToken to be liquidated
     * @param kTokenCollateral The market in which to seize collateral from the borrower
     * @param priceUpdateData data for updating prices on Pyth smart contract
     */
    function liquidateBorrowWithPriceUpdate(
        address borrower, 
        IKToken kTokenCollateral, 
        bytes[] calldata priceUpdateData
    ) external payable {
        comptroller.updatePrices(priceUpdateData);
        (uint256 err, ) = liquidateBorrowInternal(
            borrower,
            msg.value,
            kTokenCollateral
        );
        requireNoError(err, "liquidateBorrow failed");
    }

    /**
     * @notice The sender adds to reserves.
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReserves() external payable returns (uint256) {
        return _addReservesInternal(msg.value);
    }

    /**
     * @notice Send Native coin to KNative to mint
     */
    receive() external payable {
        (uint256 err, ) = mintInternal(msg.value);
        requireNoError(err, "mint failed");
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of Native, before this message
     * @dev This excludes the value of the current message, if any
     * @return The quantity of Native owned by this contract
     */
    function getCashPrior() internal view override returns (uint256) {
        (MathError err, uint256 startingBalance) = subUInt(
            address(this).balance,
            msg.value
        );
        require(err == MathError.NO_ERROR);
        return startingBalance;
    }

    /**
     * @notice Perform the actual transfer in, which is a no-op
     * @param from Address sending the Native
     * @param amount Amount of Native being sent
     * @return The actual amount of Native transferred
     */
    function doTransferIn(address from, uint256 amount)
        internal override
        returns (uint256)
    {
        // Sanity checks
        require(msg.sender == from, "sender mismatch");
        require(msg.value == amount, "value mismatch");
        return amount;
    }

    function doTransferOut(address payable to, uint256 amount) internal override {
        /* Send the Native, with minimal gas and revert on failure */
        to.transfer(amount);
    }

}
