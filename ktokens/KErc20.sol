//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./abstract/KToken.sol";
import "./abstract/KErc20Storage.sol";

/**
 * @title KEOM's KErc20 Contract
 * @notice KTokens which wrap an EIP-20 underlying
 * @author KEOM
 */
contract KErc20 is KToken, KErc20Storage {
    /**
     * @notice Initialize the new money market
     * @param underlying_ The address of the underlying asset
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     * @param admin_ Address of the administrator of this token
     */

    function initialize(
        address underlying_,
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

        // Set underlying and sanity check it
        underlying = underlying_;
        IEIP20(underlying).totalSupply();

        // Set the proper admin now that initialization is done
        admin = admin_;
    }

    /*** User Interface ***/

    /**
     * @notice Sender supplies assets into the market and receives kTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @dev Reverts upon any failure
     */
    function mint(uint256 mintAmount) external override {
        (uint256 err, ) = mintInternal(mintAmount);
        requireNoError(err, "mint failed");
    }

    /**
     * @notice Sender redeems kTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of kTokens to redeem into underlying
     */
    function redeem(uint256 redeemTokens) external override {
        redeemInternal(redeemTokens);
    }

    /**
     * @notice Sender redeems kTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to redeem
     */
    function redeemUnderlying(uint256 redeemAmount) external override{
        redeemUnderlyingInternal(redeemAmount);
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param borrowAmount The amount of the underlying asset to borrow
     */
    function borrow(uint256 borrowAmount) external override {
        borrowInternal(borrowAmount);
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay
     * @dev Reverts upon any failure
     */
    function repayBorrow(uint256 repayAmount) external override {
        (uint256 err, ) = repayBorrowInternal(repayAmount);
        requireNoError(err, "repayBorrow failed");
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay
     * @dev Reverts upon any failure
     */
    function repayBorrowBehalf(address borrower, uint256 repayAmount)
        external override
    {
        (uint256 err, ) = repayBorrowBehalfInternal(borrower, repayAmount);
        requireNoError(err, "repayBorrowBehalf failed");
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this kToken to be liquidated
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @param kTokenCollateral The market in which to seize collateral from the borrower
     * @dev Reverts upon any failure
     */
    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        IKToken kTokenCollateral
    ) external override {
        (uint256 err, ) = liquidateBorrowInternal(
            borrower,
            repayAmount,
            kTokenCollateral
        );
        requireNoError(err, "liquidateBorrow failed");
    }

    /**
     * @notice The sender liquidates the borrowers collateral and updates prices at Pyth's oracle.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this kToken to be liquidated
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @param kTokenCollateral The market in which to seize collateral from the borrower
     * @param priceUpdateData data for updating prices on Pyth smart contract
     * @dev Reverts upon any failure
     */
    function liquidateBorrowWithPriceUpdate(
        address borrower,
        uint256 repayAmount,
        IKToken kTokenCollateral,
        bytes[] calldata priceUpdateData
    ) external {
        comptroller.updatePrices(priceUpdateData);
        (uint256 err, ) = liquidateBorrowInternal(
            borrower,
            repayAmount,
            kTokenCollateral
        );
        requireNoError(err, "liquidateBorrow failed");
    }

    /**
     * @notice The sender adds to reserves.
     * @param addAmount The amount fo underlying token to add as reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReserves(uint256 addAmount) external override returns (uint256) {
        return _addReservesInternal(addAmount);
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() internal override view returns (uint256) {
        IEIP20 token = IEIP20(underlying);
        return token.balanceOf(address(this));
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
     *      This will revert due to insufficient balance or insufficient allowance.
     *      This function returns the actual amount received,
     *      which may be less than `amount` if there is a fee attached to the transfer.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferIn(address from, uint256 amount)
        internal override
        returns (uint256)
    {
        IEIP20NonStandard token = IEIP20NonStandard(underlying);
        uint256 balanceBefore = IEIP20(underlying).balanceOf(
            address(this)
        );
        token.transferFrom(from, address(this), amount);

        bool success;
        assembly {
            switch returndatasize()
            case 0 {
                // This is a non-standard ERC-20
                success := not(0) // set success to true
            }
            case 32 {
                // This is a compliant ERC-20
                returndatacopy(0, 0, 32)
                success := mload(0) // Set `success = returndata` of external call
            }
            default {
                // This is an excessively non-compliant ERC-20, revert.
                revert(0, 0)
            }
        }
        require(success, "TOKEN_TRANSFER_IN_FAILED");

        // Calculate the amount that was *actually* transferred
        uint256 balanceAfter = IEIP20(underlying).balanceOf(
            address(this)
        );
        require(balanceAfter >= balanceBefore, "TOKEN_TRANSFER_IN_OVERFLOW");
        return balanceAfter - balanceBefore; // underflow already checked above, just subtract
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False success from `transfer` and returns an explanatory
     *      error code rather than reverting. If caller has not called checked protocol's balance, this may revert due to
     *      insufficient cash held in this contract. If caller has checked protocol's balance prior to this call, and verified
     *      it is >= amount, this should not revert in normal conditions.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferOut(address payable to, uint256 amount) internal override virtual {
        IEIP20NonStandard token = IEIP20NonStandard(underlying);
        token.transfer(to, amount);

        bool success;
        assembly {
            switch returndatasize()
            case 0 {
                // This is a non-standard ERC-20
                success := not(0) // set success to true
            }
            case 32 {
                // This is a complaint ERC-20
                returndatacopy(0, 0, 32)
                success := mload(0) // Set `success = returndata` of external call
            }
            default {
                // This is an excessively non-compliant ERC-20, revert.
                revert(0, 0)
            }
        }
        require(success, "TOKEN_TRANSFER_OUT_FAILED");
    }
}
