//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../libraries/ErrorReporter.sol";
import "../libraries/ExponentialNoError.sol";
import "../interfaces/IComptroller.sol";
import "./ComptrollerStorage.sol";

interface IUnitroller {
    function admin() external view returns (address);

    function _acceptImplementation() external returns (uint256);
}

/**
 * @title Comptroller Contract
 * @author  KEOM Protocol
 * @notice Based on Compound's Comptroller with some changes inspired by BENQi.fi
 */
contract ComptrollerTempII is
    ComptrollerV9Storage,
    ComptrollerErrorReporter,
    ExponentialNoError
{
    /// @notice Emitted when an admin supports a market
    event MarketListed(IKToken kToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(IKToken kToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(IKToken kToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(
        uint256 oldCloseFactorMantissa,
        uint256 newCloseFactorMantissa
    );

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(
        IKToken kToken,
        uint256 oldCollateralFactorMantissa,
        uint256 newCollateralFactorMantissa
    );

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(
        uint256 oldLiquidationIncentiveMantissa,
        uint256 newLiquidationIncentiveMantissa
    );

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(
        PriceOracle oldPriceOracle,
        PriceOracle newPriceOracle
    );

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPausedGlobally(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(IKToken kToken, string action, bool pauseState);

    /// @notice Emitted when borrow cap for a kToken is changed
    event NewBorrowCap(IKToken indexed kToken, uint256 newBorrowCap);

    /// @notice Emitted when supply cap for a kToken is changed
    event NewSupplyCap(IKToken indexed kToken, uint256 newSupplyCap);

    /// @notice Emitted when KEOM is granted by admin
    event KeomGranted(address recipient, uint256 amount);

    bool public constant override isComptroller = true;

    /// @notice The initial Reward index for a market
    uint224 public constant marketInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint256 internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint256 internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint256 internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    address public keom;
    address public rewardUpdater;

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /**
     * @notice Updates price data of underlying oracle
     * @param priceUpdateData data for updating prices on Pyth smart contract
     */
    function updatePrices(bytes[] calldata priceUpdateData) public override {
        oracle.updateUnderlyingPrices(priceUpdateData);
    }

    /*** Assets You Are In ***/


    function fixAccountsAssetsIn(address account, IKToken[] calldata kTokens) external {
        require(msg.sender == admin, "");
        accountAssets[account] = kTokens;
    }

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account)
        external
        view
        returns (IKToken[] memory)
    {
        return accountAssets[account];
    }

    /**
     * @notice Returns whether the given token is listed market
     * @param kToken The kToken to check
     * @return True if is market, otherwise false.
     */
    function isMarket(address kToken) external view override returns (bool) {
        return markets[kToken].isListed;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param kToken The kToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, IKToken kToken)
        external
        view
        returns (bool)
    {
        return accountMembership[address(kToken)][account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param kTokens The list of addresses of the kToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory kTokens)
        public
        override
        returns (uint256[] memory)
    {
        uint256 len = kTokens.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            results[i] = uint256(
                addToMarketInternal(IKToken(kTokens[i]), msg.sender)
            );
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param kToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(IKToken kToken, address borrower)
        internal
        returns (Error)
    {
        if (!markets[address(kToken)].isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (accountMembership[address(kToken)][borrower]) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        accountMembership[address(kToken)][borrower] = true;
        accountAssets[borrower].push(kToken);

        emit MarketEntered(kToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param kTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address kTokenAddress)
        external
        override
        returns (uint256)
    {
        IKToken kToken = IKToken(kTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the kToken */
        (uint256 oErr, uint256 tokensHeld, uint256 amountOwed, ) = kToken
            .getAccountSnapshot(msg.sender);
        require(oErr == 0, "getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return
                fail(
                    Error.NONZERO_BORROW_BALANCE,
                    FailureInfo.EXIT_MARKET_BALANCE_OWED
                );
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint256 allowed = redeemAllowedInternal(
            kTokenAddress,
            msg.sender,
            tokensHeld
        );
        if (allowed != 0) {
            return
                failOpaque(
                    Error.REJECTION,
                    FailureInfo.EXIT_MARKET_REJECTION,
                    allowed
                );
        }

        /* Return true if the sender is not already ‘in’ the market */
        if (!accountMembership[address(kToken)][msg.sender]) {
            return uint256(Error.NO_ERROR);
        }

        /* Set kToken account membership to false */
        delete accountMembership[address(kToken)][msg.sender];

        /* Delete kToken from the account’s list of assets */
        // load into memory for faster iteration
        IKToken[] memory userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 assetIndex = len;
        for (uint256 i = 0; i < len; i++) {
            if (userAssetList[i] == kToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        IKToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(kToken, msg.sender);

        return uint256(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param kToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(
        address kToken,
        address minter,
        uint256 mintAmount
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        mintAmount; // not used yet
        require(!guardianPaused[kToken].mint, "mint is paused");

        if (!markets[kToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

         uint256 supplyCap = supplyCaps[kToken];
        // Supply cap of 0 corresponds to unlimited supplying
        if (supplyCap != 0) {
            uint256 reserves;
            uint cash = IKToken(kToken).getCash();
            // if native token, we decrease mintAmount (msg.value), because `msg.value` has already been transferred to the oNative contract. 
            (, bytes memory underlyingData) = kToken.staticcall(
                abi.encodeWithSignature("underlying()")
            );
            if(underlyingData.length == 0) {
                cash -= mintAmount;
            }
            uint borrows = IKToken(kToken).totalBorrows();
            // total reserves doesn't exist in the interface because it's a state variable
            (, bytes memory reservesData) = kToken.staticcall(
                abi.encodeWithSignature("totalReserves()")
            );
            assembly {
                reserves := mload(add(reservesData, 0x20))
            }

            uint256 totalSupply = cash + borrows - reserves;
            uint256 maxSupply = supplyCap - totalSupply;

            require(mintAmount <= maxSupply, "supply cap reached");
        }

        // Sets an asset automatically as collateral if the user has no
        // kToken (on first deposit) and if the asset allows auto-collateralization
        if (
            IKToken(kToken).balanceOf(minter) == 0 &&
            markets[kToken].autoCollaterize
        ) {
            addToMarketInternal(IKToken(kToken), minter);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param kToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of kTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(
        address kToken,
        address redeemer,
        uint256 redeemTokens
    ) external override returns (uint256) {
        require(!guardianPaused[kToken].redeem, "redeem is paused");

        uint256 allowed = redeemAllowedInternal(kToken, redeemer, redeemTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        return uint256(Error.NO_ERROR);
    }

    function redeemAllowedInternal(
        address kToken,
        address redeemer,
        uint256 redeemTokens
    ) internal view returns (uint256) {
        if (!markets[kToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!accountMembership[kToken][redeemer]) {
            return uint256(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (
            Error err,
            ,
            uint256 shortfall,

        ) = getHypotheticalAccountLiquidityInternal(
                redeemer,
                IKToken(kToken),
                redeemTokens,
                0
            );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param kToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(
        address kToken,
        address redeemer,
        uint256 redeemAmount,
        uint256 redeemTokens
    ) external pure override {
        // Shh - currently unused
        kToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        require(redeemTokens != 0 || redeemAmount == 0, "redeemTokens zero");
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param kToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(
        address kToken,
        address borrower,
        uint256 borrowAmount
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!guardianPaused[kToken].borrow, "borrow is paused");
        if (!markets[kToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (!accountMembership[kToken][borrower]) {
            // only kTokens may call borrowAllowed if borrower not in market
            require(msg.sender == kToken, "sender must be kToken");

            // attempt to add borrower to the market
            Error addErr = addToMarketInternal(IKToken(msg.sender), borrower);
            if (addErr != Error.NO_ERROR) {
                return uint256(addErr);
            }

            // it should be impossible to break the important invariant
            assert(accountMembership[kToken][borrower]);
        }

        if (oracle.getUnderlyingPrice(IKToken(kToken)) == 0) {
            return uint256(Error.PRICE_ERROR);
        }

        uint256 borrowCap = borrowCaps[kToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            require(
                (IKToken(kToken).totalBorrows() + borrowAmount) < borrowCap,
                "borrow cap reached"
            );
        }

        (
            Error err,
            ,
            uint256 shortfall,

        ) = getHypotheticalAccountLiquidityInternal(
                borrower,
                IKToken(kToken),
                0,
                borrowAmount
            );

        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param kToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address kToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external override returns (uint256) {
        require(!guardianPaused[kToken].repay, "repay is paused");
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[kToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur and calculates dynamic liquidation incentive
     * @param kTokenBorrowed Asset which was borrowed by the borrower
     * @param kTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address kTokenBorrowed,
        address kTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external view override returns (uint256, uint256) {
        // Shh - currently unused
        liquidator;

        if (
            !markets[kTokenBorrowed].isListed ||
            !markets[kTokenCollateral].isListed
        ) {
            return (uint256(Error.MARKET_NOT_LISTED), 0);
        }

        uint256 borrowBalance = IKToken(kTokenBorrowed).borrowBalanceStored(
            borrower
        );

        uint256 dynamicLiquidationIncentiveMantissa;

        /* allow accounts to be liquidated if the market is deprecated */
        if (isDeprecated(IKToken(kTokenBorrowed))) {
            require(
                borrowBalance >= repayAmount,
                "Can not repay more than the total borrow"
            );

            dynamicLiquidationIncentiveMantissa = 1e18;
        } else {
            /* The borrower must have shortfall in order to be liquidatable */
            (
                Error err,
                ,
                uint256 shortfall,
                uint256 liquidationIncentive
            ) = getHypotheticalAccountLiquidityInternal(
                    borrower,
                    IKToken(address(0)),
                    0,
                    0
                );

            if (err != Error.NO_ERROR) {
                return (uint256(err), 0);
            }

            dynamicLiquidationIncentiveMantissa = liquidationIncentive;

            if (shortfall == 0) {
                return (uint256(Error.INSUFFICIENT_SHORTFALL), 0);
            }

            /* The liquidator may not repay more than what is allowed by the closeFactor */
            Exp memory defaultCloseFactor = Exp({mantissa: closeFactorMantissa});
            Exp memory dynamicLiquidationIncentive = Exp({mantissa: dynamicLiquidationIncentiveMantissa});

            /*  closeFactor = 10 * ( ( ( dynamicLiquidationIncentive - 1 ) * defaultCloseFactor ) + ( defaultLiquidationIncentive - dynamicLiquidationIncentive ) )
                which converts to:
                closeFactor = 10 * (defaultCloseFactor * liquidationIncentive + defaultLiquidationIncentive - defaultCloseFactor - liquidationIncentive) 
            */
            Exp memory downscaledCloseFactor = sub_(
                sub_(
                    add_(
                        mul_(
                            defaultCloseFactor, 
                            dynamicLiquidationIncentive), 
                        Exp({mantissa: liquidationIncentiveMantissa})), 
                    defaultCloseFactor), 
                dynamicLiquidationIncentive);

            uint256 closeFactor = mul_(downscaledCloseFactor, 10).mantissa;
            if (closeFactor > 1e18) {
                closeFactor = 1e18;
            } 

            uint256 maxClose = mul_ScalarTruncate(
                Exp({mantissa: closeFactor}),
                borrowBalance
            );
            if (repayAmount > maxClose) {
                return (uint256(Error.TOO_MUCH_REPAY), 0);
            }
        }

        return (uint256(Error.NO_ERROR), dynamicLiquidationIncentiveMantissa);
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param kTokenCollateral Asset which was used as collateral and will be seized
     * @param kTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address kTokenCollateral,
        address kTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external view override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        liquidator;
        seizeTokens;

        if (
            !markets[kTokenCollateral].isListed ||
            !markets[kTokenBorrowed].isListed
        ) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (
            IKToken(kTokenCollateral).comptroller() !=
            IKToken(kTokenBorrowed).comptroller()
        ) {
            return uint256(Error.COMPTROLLER_MISMATCH);
        }

        require(accountMembership[kTokenCollateral][borrower], "borrower exited collateral market");

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param kToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of kTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address kToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint256 allowed = redeemAllowedInternal(kToken, src, transferTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        return uint256(Error.NO_ERROR);
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `kTokenBalance` is the number of kTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint256 sumCollateral;
        uint256 totalCollateral;
        uint256 sumBorrowPlusEffects;
        uint256 dynamicLiquidationIncentive;
        uint256 kTokenBalance;
        uint256 borrowBalance;
        uint256 exchangeRateMantissa;
        uint256 oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        (
            Error err,
            uint256 liquidity,
            uint256 shortfall, 
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                IKToken(address(0)),
                0,
                0
            );

        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param kTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements,
     *          dynamic liquidation incentive)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address kTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    )
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        (
            Error err,
            uint256 liquidity,
            uint256 shortfall,
            uint256 liquidationIncentive
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                IKToken(kTokenModify),
                redeemTokens,
                borrowAmount
            );
        return (uint256(err), liquidity, shortfall, liquidationIncentive);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param kTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral kToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements,
     *          dynamic liquidation incentive)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        IKToken kTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    )
        internal
        view
        returns (
            Error,
            uint256,
            uint256,
            uint256
        )
    {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint256 oErr;

        // For each asset the account is in
        IKToken[] memory assets = accountAssets[account];
        for (uint256 i = 0; i < assets.length; i++) {
            IKToken asset = assets[i];

            // Read the balances and exchange rate from the kToken
            (
                oErr,
                vars.kTokenBalance,
                vars.borrowBalance,
                vars.exchangeRateMantissa
            ) = asset.getAccountSnapshot(account);
            if (oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0, 0);
            }
            vars.collateralFactor = Exp({
                mantissa: markets[address(asset)].collateralFactorMantissa
            });
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(
                mul_(vars.collateralFactor, vars.exchangeRate),
                vars.oraclePrice
            );

            // sumCollateral += tokensToDenom * kTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(
                vars.tokensToDenom,
                vars.kTokenBalance,
                vars.sumCollateral
            );

            vars.totalCollateral = mul_ScalarTruncateAddUInt(
                mul_(vars.exchangeRate, vars.oraclePrice),
                vars.kTokenBalance,
                vars.totalCollateral
            );

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );

            // Calculate effects of interacting with kTokenModify
            if (asset == kTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.tokensToDenom,
                    redeemTokens,
                    vars.sumBorrowPlusEffects
                );

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.oraclePrice,
                    borrowAmount,
                    vars.sumBorrowPlusEffects
                );
            }
        }
       
        if (vars.sumBorrowPlusEffects == 0) {
            vars.dynamicLiquidationIncentive = liquidationIncentiveMantissa;
        }
        else {
            vars.dynamicLiquidationIncentive = div_(
                vars.totalCollateral,
                Exp({mantissa: vars.sumBorrowPlusEffects})
            );
        }

        if (vars.dynamicLiquidationIncentive >= liquidationIncentiveMantissa) {
            vars.dynamicLiquidationIncentive = liquidationIncentiveMantissa;
        }
        else if(vars.dynamicLiquidationIncentive != 0) {
            unchecked { vars.dynamicLiquidationIncentive -= 1; }
        }

        // These are safe, as the underflow condition is checked first
        unchecked {
            if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
                return (
                    Error.NO_ERROR,
                    vars.sumCollateral - vars.sumBorrowPlusEffects,
                    0,
                    vars.dynamicLiquidationIncentive
                );
            } else {
                return (
                    Error.NO_ERROR,
                    0,
                    vars.sumBorrowPlusEffects - vars.sumCollateral,
                    vars.dynamicLiquidationIncentive
                );
            }
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in kToken.liquidateBorrowFresh)
     * @param kTokenBorrowed The address of the borrowed kToken
     * @param kTokenCollateral The address of the collateral kToken
     * @param actualRepayAmount The amount of kTokenBorrowed underlying to convert into kTokenCollateral tokens
     * @param dynamicLiquidationIncentive The liquidation incentive calculated based on LTV
     * @return (errorCode, number of kTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address kTokenBorrowed,
        address kTokenCollateral,
        uint256 actualRepayAmount,
        uint256 dynamicLiquidationIncentive
    ) public view override returns (uint256, uint256) {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowedMantissa = oracle.getUnderlyingPrice(
            IKToken(kTokenBorrowed)
        );
        uint256 priceCollateralMantissa = oracle.getUnderlyingPrice(
            IKToken(kTokenCollateral)
        );

        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint256(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint256 exchangeRateMantissa = IKToken(kTokenCollateral)
            .exchangeRateStored(); // Note: reverts on error

        Exp memory numerator = mul_(
            Exp({mantissa: dynamicLiquidationIncentive}),
            Exp({mantissa: priceBorrowedMantissa})
        );
        Exp memory denominator = mul_(
            Exp({mantissa: priceCollateralMantissa}),
            Exp({mantissa: exchangeRateMantissa})
        );
        Exp memory ratio = div_(numerator, denominator);

        uint256 seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint256(Error.NO_ERROR), seizeTokens);
    }

    /*** Functions with price update ***/

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount after updating prices at Pyth's oracle
     * @dev Used in liquidation (called in kToken.liquidateBorrowFresh)
     * @param kTokenBorrowed The address of the borrowed kToken
     * @param kTokenCollateral The address of the collateral kToken
     * @param actualRepayAmount The amount of kTokenBorrowed underlying to convert into kTokenCollateral tokens
     * @param dynamicLiquidationIncentive The liquidation incentive calculated based on LTV
     * @param priceUpdateData data for updating prices on Pyth smart contract
     * @return (errorCode, number of kTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokensWithPriceUpdate(
        address kTokenBorrowed,
        address kTokenCollateral,
        uint256 actualRepayAmount,
        uint256 dynamicLiquidationIncentive,
        bytes[] calldata priceUpdateData
    ) external returns (uint256, uint256) {
        updatePrices(priceUpdateData);
        return liquidateCalculateSeizeTokens(
            kTokenBorrowed, 
            kTokenCollateral, 
            actualRepayAmount, 
            dynamicLiquidationIncentive);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements after updating prices at Pyth's oracle
     * @param account the account whose liquidity is returned
     * @param priceUpdateData data for updating prices on Pyth smart contract
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityWithPriceUpdate(address account, bytes[] calldata priceUpdateData)
        public returns (uint256, uint256 ,uint256) 
    {
        updatePrices(priceUpdateData);
        return getAccountLiquidity(account);
    }

        /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed after updating prices at Pyth's oracle
     * @param kTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @param priceUpdateData data for updating prices on Pyth smart contract
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements,
     *          dynamic liquidation incentive)
     */
    function getHypotheticalAccountLiquidityWithPriceUpdate(
        address account,
        address kTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount,
        bytes[] calldata priceUpdateData
    ) public returns (uint256, uint256, uint256, uint256) {
        updatePrices(priceUpdateData);
        return getHypotheticalAccountLiquidity(account, kTokenModify, redeemTokens, borrowAmount);
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new price oracle for the comptroller
     * @dev Admin function to set a new price oracle
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK
                );
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @dev Admin function to set closeFactor
     * @param newCloseFactorMantissa New close factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure
     */
    function _setCloseFactor(uint256 newCloseFactorMantissa)
        external
        onlyAdmin
        returns (uint256)
    {
        uint256 oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Admin function to set per-market collateralFactor
     * @param kToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(
        IKToken kToken,
        uint256 newCollateralFactorMantissa
    ) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK
                );
        }

        // Verify market is listed
        Market storage market = markets[address(kToken)];
        if (!market.isListed) {
            return
                fail(
                    Error.MARKET_NOT_LISTED,
                    FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS
                );
        }

        Exp memory newCollateralFactorExp = Exp({
            mantissa: newCollateralFactorMantissa
        });

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return
                fail(
                    Error.INVALID_COLLATERAL_FACTOR,
                    FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION
                );
        }

        // If collateral factor != 0, fail if price == 0
        if (
            newCollateralFactorMantissa != 0 &&
            oracle.getUnderlyingPrice(kToken) == 0
        ) {
            return
                fail(
                    Error.PRICE_ERROR,
                    FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE
                );
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint256 oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(
            kToken,
            oldCollateralFactorMantissa,
            newCollateralFactorMantissa
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets liquidationIncentive
     * @dev Admin function to set liquidationIncentive
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(uint256 newLiquidationIncentiveMantissa)
        external
        returns (uint256)
    {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK
                );
        }

        // Save current value for use in log
        uint256 oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(
            oldLiquidationIncentiveMantissa,
            newLiquidationIncentiveMantissa
        );

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Admin function to set isListed and add support for the market
     * @param kToken The address of the market (token) to list
     * @param _autoCollaterize Boolean value representing whether the market should have auto-collateralisation enabled
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(IKToken kToken, bool _autoCollaterize)
        external
        returns (uint256)
    {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SUPPORT_MARKET_OWNER_CHECK
                );
        }

        if (markets[address(kToken)].isListed) {
            return
                fail(
                    Error.MARKET_ALREADY_LISTED,
                    FailureInfo.SUPPORT_MARKET_EXISTS
                );
        }

        kToken.isKToken(); // Sanity check to make sure its really a IKToken

        markets[address(kToken)] = Market({
            isListed: true,
            autoCollaterize: _autoCollaterize,
            collateralFactorMantissa: 0
        });

        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != IKToken(kToken), "market already added");
        }

        allMarkets.push(kToken);
        _initializeMarket(address(kToken));

        emit MarketListed(kToken);

        return uint256(Error.NO_ERROR);
    }

    function _initializeMarket(address kToken) internal {
        uint32 timestamp = safe32(getTimestamp());

        MarketState storage supState = supplyState[kToken];
        MarketState storage borState = borrowState[kToken];

        /*
         * Update market state indices
         */
        if (supState.index == 0) {
            // Initialize supply state index with default value
            supState.index = marketInitialIndex;
        }

        if (borState.index == 0) {
            // Initialize borrow state index with default value
            borState.index = marketInitialIndex;
        }

        /*
         * Update market state timestamps
         */
        supState.timestamp = borState.timestamp = timestamp;
    }

    /**
     * @notice Set the given borrow caps for the given kToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Admin or capGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
     * @param kTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(
        IKToken[] calldata kTokens,
        uint256[] calldata newBorrowCaps
    ) external {
        require(
            msg.sender == admin || msg.sender == capGuardian,
            "only admin or capGuardian"
        );

        uint256 numMarkets = kTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(
            numMarkets != 0 && numMarkets == numBorrowCaps,
            "invalid input"
        );

        for (uint256 i = 0; i < numMarkets; i++) {
            borrowCaps[address(kTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(kTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Set the given supply caps for the given kToken markets. Supplying that brings max supply to or above supply cap will revert.
     * @dev Admin or capGuardian function to set the supply caps. A supply cap of 0 corresponds to unlimited supplying.
     * @param kTokens The addresses of the markets (tokens) to change the supply caps for
     * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to unlimited supplying.
     */
    function _setMarketSupplyCaps(
        IKToken[] calldata kTokens,
        uint256[] calldata newSupplyCaps
    ) external {
        require(
            msg.sender == admin,
            "only admin"
        );

        uint256 numMarkets = kTokens.length;
        uint256 numSupplyCaps = newSupplyCaps.length;

        require(
            numMarkets != 0 && numMarkets == numSupplyCaps,
            "invalid input"
        );

        for (uint256 i = 0; i < numMarkets; i++) {
            supplyCaps[address(kTokens[i])] = newSupplyCaps[i];
            emit NewSupplyCap(kTokens[i], newSupplyCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian)
        public
        returns (uint256)
    {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK
                );
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint256(Error.NO_ERROR);
    }

    function onlyAdminOrGuardian() internal view {
        require(
            msg.sender == admin || msg.sender == pauseGuardian,
            "only pause guardian and admin"
        );
    }

    function _setMintPaused(IKToken kToken, bool state) public returns (bool) {
        require(
            markets[address(kToken)].isListed,
            "cannot pause: market not listed"
        );
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin can unpause");

        guardianPaused[address(kToken)].mint = state;
        emit ActionPaused(kToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(
        IKToken kToken,
        bool state
    ) public returns (bool) {
        require(
            markets[address(kToken)].isListed,
            "cannot pause: market not listed"
        );
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin can unpause");

        guardianPaused[address(kToken)].borrow = state;
        emit ActionPaused(kToken, "Borrow", state);
        return state;
    }

    function _setRedeemPaused(
        IKToken kToken,
        bool state
    ) public returns (bool) {
        require(
            markets[address(kToken)].isListed,
            "cannot pause: market not listed"
        );
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin can unpause");

        guardianPaused[address(kToken)].redeem = state;
        emit ActionPaused(kToken, "Redeem", state);
        return state;
    }

    function _setRepayPaused(
        IKToken kToken,
        bool state
    ) public returns (bool) {
        require(
            markets[address(kToken)].isListed,
            "cannot pause: market not listed"
        );
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin can unpause");

        guardianPaused[address(kToken)].repay = state;
        emit ActionPaused(kToken, "Repay", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPausedGlobally("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPausedGlobally("Seize", state);
        return state;
    }

    function _become(IUnitroller unitroller) public {
        require(
            msg.sender == unitroller.admin(),
            "only unitroller admin can _become"
        );
        require(
            unitroller._acceptImplementation() == 0,
            "change not authorized"
        );
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view override returns (IKToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Returns true if the given kToken market has been deprecated
     * @dev All borrows in a deprecated kToken market can be immediately liquidated
     * @param kToken The market to check if deprecated
     */
    function isDeprecated(IKToken kToken) public view returns (bool) {
        return
            markets[address(kToken)].collateralFactorMantissa == 0 &&
            guardianPaused[address(kToken)].borrow &&
            kToken.reserveFactorMantissa() == 1e18;
    }

    function getTimestamp() public view returns (uint256) {
        return block.timestamp;
    }

    /**
     * Pause or unpause all protocol functionality
     * - Pause can be invoked by admin or pause guardian
     * - Unpause can be invoked by admin only
     */
    function setProtocolPaused(bool _paused) public {

        for (uint i; i < allMarkets.length;) {
            IKToken market = allMarkets[i];
            _setBorrowPaused(market, _paused);
            _setMintPaused(market, _paused);
            _setRedeemPaused(market, _paused);
            _setRepayPaused(market, _paused);

            unchecked {
                ++i;
            }
        }
        _setSeizePaused(_paused);
        _setTransferPaused(_paused);
    }

    /**
     * @notice payable function needed to receive NATIVE
     */
    receive() external payable {}
}