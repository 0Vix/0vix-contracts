//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../libraries/ErrorReporter.sol";
import "../libraries/ExponentialNoError.sol";
import "../interfaces/IComptroller.sol";
import "./ComptrollerStorage.sol";

interface I0vix {
    function transfer(address, uint256) external;

    function balanceOf(address) external view returns (uint256);
}

interface IUnitroller {
    function admin() external view returns (address);

    function _acceptImplementation() external returns (uint256);
}

/**
 * @title Comptroller Contract
 * @author 0VIX Protocol
 * @notice Based on Compound's Comptroller with some changes inspired by BENQi.fi
 */
contract Comptroller is
    ComptrollerV9Storage,
    ComptrollerErrorReporter,
    ExponentialNoError
{
    /// @notice Emitted when an admin supports a market
    event MarketListed(IOToken oToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(IOToken oToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(IOToken oToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(
        uint256 oldCloseFactorMantissa,
        uint256 newCloseFactorMantissa
    );

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(
        IOToken oToken,
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
    event ActionPaused(IOToken oToken, string action, bool pauseState);

    /// @notice Emitted when a new borrow-side Reward speed is calculated for a market
    event RewardBorrowSpeedUpdated(IOToken indexed oToken, uint256 newSpeed);

    /// @notice Emitted when a new supply-side Reward speed is calculated for a market
    event RewardSupplySpeedUpdated(IOToken indexed oToken, uint256 newSpeed);

    /// @notice Emitted when a new Reward speed is set for a contributor
    event ContributorRewardSpeedUpdated(
        address indexed contributor,
        uint256 newSpeed
    );

    /// @notice Emitted when VIX is distributed to a supplier
    event DistributedSupplierReward(
        IOToken indexed oToken,
        address indexed supplier,
        uint256 tokenDelta,
        uint256 tokenSupplyIndex
    );

    /// @notice Emitted when VIX is distributed to a borrower
    event DistributedBorrowerReward(
        IOToken indexed oToken,
        address indexed borrower,
        uint256 tokenDelta,
        uint256 tokenBorrowIndex
    );

    /// @notice Emitted when borrow cap for a oToken is changed
    event NewBorrowCap(IOToken indexed oToken, uint256 newBorrowCap);

    /// @notice Emitted when supply cap for a oToken is changed
    event NewSupplyCap(IOToken indexed oToken, uint256 newSupplyCap);

    /// @notice Emitted when VIX is granted by admin
    event VixGranted(address recipient, uint256 amount);

    /// @notice Emitted when VIX rewards are being claimed for a user
    event VixClaimed(address recipient, uint256 amount);

    bool public constant override isComptroller = true;

    /// @notice The initial Reward index for a market
    uint224 public constant marketInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint256 internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint256 internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint256 internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    address public vixAddress;
    address public rewardUpdater;

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account)
        external
        view
        returns (IOToken[] memory)
    {
        return accountAssets[account];
    }

    /**
     * @notice Returns whether the given token is listed market
     * @param oToken The oToken to check
     * @return True if is market, otherwise false.
     */
    function isMarket(address oToken) external view override returns (bool) {
        return markets[oToken].isListed;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param oToken The oToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, IOToken oToken)
        external
        view
        returns (bool)
    {
        return accountMembership[address(oToken)][account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param oTokens The list of addresses of the oToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory oTokens)
        public
        override
        returns (uint256[] memory)
    {
        uint256 len = oTokens.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i; i < len;) {
            results[i] = uint256(
                addToMarketInternal(IOToken(oTokens[i]), msg.sender)
            );
            unchecked {++i;}
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param oToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(IOToken oToken, address borrower)
        internal
        returns (Error)
    {
        if (!markets[address(oToken)].isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (accountMembership[address(oToken)][borrower]) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        accountMembership[address(oToken)][borrower] = true;
        accountAssets[borrower].push(oToken);

        emit MarketEntered(oToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param oTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address oTokenAddress)
        external
        override
        returns (uint256)
    {
        IOToken oToken = IOToken(oTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the oToken */
        (uint256 oErr, uint256 tokensHeld, uint256 amountOwed, ) = oToken
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
            oTokenAddress,
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
        if (!accountMembership[address(oToken)][msg.sender]) {
            return uint256(Error.NO_ERROR);
        }

        /* Set oToken account membership to false */
        delete accountMembership[address(oToken)][msg.sender];

        /* Delete oToken from the account’s list of assets */
        // load into memory for faster iteration
        IOToken[] memory userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 assetIndex = len;
        for (uint256 i = 0; i < len; i++) {
            if (userAssetList[i] == oToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        IOToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(oToken, msg.sender);

        return uint256(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param oToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(
        address oToken,
        address minter,
        uint256 mintAmount
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        mintAmount; // not used yet
        require(!guardianPaused[oToken].mint, "mint paused");

        if (!markets[oToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        uint256 supplyCap = supplyCaps[oToken];
        // Supply cap of 0 corresponds to unlimited supplying
        if (supplyCap != 0) {
            uint256 reserves;
            uint cash = IOToken(oToken).getCash();
            // if native token, we decrease mintAmount (msg.value), because `msg.value` has already been transferred to the oNative contract. 
            (, bytes memory underlyingData) = oToken.staticcall(
                abi.encodeWithSignature("underlying()")
            );
            if(underlyingData.length == 0) {
                cash -= mintAmount;
            }
            uint borrows = IOToken(oToken).totalBorrows();
            // total reserves doesn't exist in the interface because it's a state variable
            (, bytes memory reservesData) = oToken.staticcall(
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
        // oToken (on first deposit) and if the asset allows auto-collateralization
        if (
            IOToken(oToken).balanceOf(minter) == 0 &&
            markets[oToken].autoCollaterize
        ) {
            addToMarketInternal(IOToken(oToken), minter);
        }

        updateAndDistributeSupplierRewardsForToken(oToken, minter);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param oToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of oTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(
        address oToken,
        address redeemer,
        uint256 redeemTokens
    ) external override returns (uint256) {
        require(!guardianPaused[oToken].redeem, "redeem paused");

        uint256 allowed = redeemAllowedInternal(oToken, redeemer, redeemTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        updateAndDistributeSupplierRewardsForToken(oToken, redeemer);

        return uint256(Error.NO_ERROR);
    }

    function redeemAllowedInternal(
        address oToken,
        address redeemer,
        uint256 redeemTokens
    ) internal view returns (uint256) {
        if (!markets[oToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!accountMembership[oToken][redeemer]) {
            return uint256(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (
            Error err,
            ,
            uint256 shortfall,

        ) = getHypotheticalAccountLiquidityInternal(
                redeemer,
                IOToken(oToken),
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
     * @param oToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(
        address oToken,
        address redeemer,
        uint256 redeemAmount,
        uint256 redeemTokens
    ) external pure override {
        // Shh - currently unused
        oToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        require(redeemTokens != 0 || redeemAmount == 0, "redeem zero");
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param oToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(
        address oToken,
        address borrower,
        uint256 borrowAmount
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!guardianPaused[oToken].borrow, "borrow paused");
        if (!markets[oToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (!accountMembership[oToken][borrower]) {
            // only oTokens may call borrowAllowed if borrower not in market
            require(msg.sender == oToken, "sender must be oToken");

            // attempt to add borrower to the market
            Error addErr = addToMarketInternal(IOToken(msg.sender), borrower);
            if (addErr != Error.NO_ERROR) {
                return uint256(addErr);
            }

            // it should be impossible to break the important invariant
            assert(accountMembership[oToken][borrower]);
        }

        if (oracle.getUnderlyingPrice(IOToken(oToken)) == 0) {
            return uint256(Error.PRICE_ERROR);
        }

        uint256 borrowCap = borrowCaps[oToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            require(
                (IOToken(oToken).totalBorrows() + borrowAmount) < borrowCap,
                "borrow cap reached"
            );
        }

        (
            Error err,
            ,
            uint256 shortfall,

        ) = getHypotheticalAccountLiquidityInternal(
                borrower,
                IOToken(oToken),
                0,
                borrowAmount
            );

        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        updateAndDistributeBorrowerRewardsForToken(oToken, borrower);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param oToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address oToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external override returns (uint256) {
        require(!guardianPaused[oToken].repay, "repay paused");
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[oToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateAndDistributeBorrowerRewardsForToken(oToken, borrower);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur and calculates dynamic liquidation incentive
     * @param oTokenBorrowed Asset which was borrowed by the borrower
     * @param oTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address oTokenBorrowed,
        address oTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external view override returns (uint256, uint256) {
        // Shh - currently unused
        liquidator;

        if (
            !markets[oTokenBorrowed].isListed ||
            !markets[oTokenCollateral].isListed
        ) {
            return (uint256(Error.MARKET_NOT_LISTED), 0);
        }

        uint256 borrowBalance = IOToken(oTokenBorrowed).borrowBalanceStored(
            borrower
        );

        uint256 dynamicLiquidationIncentiveMantissa;

        /* allow accounts to be liquidated if the market is deprecated */
        if (isDeprecated(IOToken(oTokenBorrowed))) {
            require(
                borrowBalance >= repayAmount,
                "Can't repay >= total borrow"
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
                    IOToken(address(0)),
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
     * @param oTokenCollateral Asset which was used as collateral and will be seized
     * @param oTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address oTokenCollateral,
        address oTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize paused");

        // Shh - currently unused
        seizeTokens;

        if (
            !markets[oTokenCollateral].isListed ||
            !markets[oTokenBorrowed].isListed
        ) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (
            IOToken(oTokenCollateral).comptroller() !=
            IOToken(oTokenBorrowed).comptroller()
        ) {
            return uint256(Error.COMPTROLLER_MISMATCH);
        }

        require(accountMembership[oTokenCollateral][borrower], "borrower exited collateral market");

        // Keep the flywheel moving
        updateRewardSupplyIndex(oTokenCollateral);
        distributeSupplierReward(oTokenCollateral, borrower);
        distributeSupplierReward(oTokenCollateral, liquidator);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param oToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of oTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address oToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint256 allowed = redeemAllowedInternal(oToken, src, transferTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateRewardSupplyIndex(oToken);
        distributeSupplierReward(oToken, src);
        distributeSupplierReward(oToken, dst);

        return uint256(Error.NO_ERROR);
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `oTokenBalance` is the number of oTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint256 sumCollateral;
        uint256 totalCollateral;
        uint256 sumBorrowPlusEffects;
        uint256 dynamicLiquidationIncentive;
        uint256 oTokenBalance;
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
                IOToken(address(0)),
                0,
                0
            );

        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param oTokenModify The market to hypothetically redeem/borrow in
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
        address oTokenModify,
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
                IOToken(oTokenModify),
                redeemTokens,
                borrowAmount
            );
        return (uint256(err), liquidity, shortfall, liquidationIncentive);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param oTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral oToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements,
     *          dynamic liquidation incentive)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        IOToken oTokenModify,
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
        IOToken[] memory assets = accountAssets[account];
        for (uint256 i = 0; i < assets.length; i++) {
            IOToken asset = assets[i];

            // Read the balances and exchange rate from the oToken
            (
                oErr,
                vars.oTokenBalance,
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

            // sumCollateral += tokensToDenom * oTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(
                vars.tokensToDenom,
                vars.oTokenBalance,
                vars.sumCollateral
            );

            vars.totalCollateral = mul_ScalarTruncateAddUInt(
                mul_(vars.exchangeRate, vars.oraclePrice),
                vars.oTokenBalance,
                vars.totalCollateral
            );

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );

            // Calculate effects of interacting with oTokenModify
            if (asset == oTokenModify) {
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
     * @dev Used in liquidation (called in oToken.liquidateBorrowFresh)
     * @param oTokenBorrowed The address of the borrowed oToken
     * @param oTokenCollateral The address of the collateral oToken
     * @param actualRepayAmount The amount of oTokenBorrowed underlying to convert into oTokenCollateral tokens
     * @param dynamicLiquidationIncentive The liquidation incentive calculated based on LTV
     * @return (errorCode, number of oTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address oTokenBorrowed,
        address oTokenCollateral,
        uint256 actualRepayAmount,
        uint256 dynamicLiquidationIncentive
    ) external view override returns (uint256, uint256) {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowedMantissa = oracle.getUnderlyingPrice(
            IOToken(oTokenBorrowed)
        );
        uint256 priceCollateralMantissa = oracle.getUnderlyingPrice(
            IOToken(oTokenCollateral)
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
        uint256 exchangeRateMantissa = IOToken(oTokenCollateral)
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
     * @param oToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(
        IOToken oToken,
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
        Market storage market = markets[address(oToken)];
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
            oracle.getUnderlyingPrice(oToken) == 0
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
            oToken,
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
     * @param oToken The address of the market (token) to list
     * @param _autoCollaterize Boolean value representing whether the market should have auto-collateralisation enabled
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(IOToken oToken, bool _autoCollaterize)
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

        if (markets[address(oToken)].isListed) {
            return
                fail(
                    Error.MARKET_ALREADY_LISTED,
                    FailureInfo.SUPPORT_MARKET_EXISTS
                );
        }

        oToken.isOToken(); // Sanity check to make sure its really a IOToken

        markets[address(oToken)] = Market({
            isListed: true,
            autoCollaterize: _autoCollaterize,
            collateralFactorMantissa: 0
        });

        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != IOToken(oToken), "market already added");
        }

        allMarkets.push(oToken);
        _initializeMarket(address(oToken));

        emit MarketListed(oToken);

        return uint256(Error.NO_ERROR);
    }

    function _initializeMarket(address oToken) internal {
        uint32 timestamp = safe32(getTimestamp());

        MarketState storage supState = supplyState[oToken];
        MarketState storage borState = borrowState[oToken];

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
     * @notice Set the given borrow caps for the given oToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
     * @param oTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(
        IOToken[] calldata oTokens,
        uint256[] calldata newBorrowCaps
    ) external {
        require(
            msg.sender == admin,
            "only admin"
        );

        uint256 numMarkets = oTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(
            numMarkets != 0 && numMarkets == numBorrowCaps,
            "invalid input"
        );

        for (uint256 i = 0; i < numMarkets; i++) {
            borrowCaps[address(oTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(oTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Set the given supply caps for the given oToken markets. Supplying that brings max supply to or above supply cap will revert.
     * @dev Admin or capGuardian function to set the supply caps. A supply cap of 0 corresponds to unlimited supplying.
     * @param oTokens The addresses of the markets (tokens) to change the supply caps for
     * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to unlimited supplying.
     */
    function _setMarketSupplyCaps(
        IOToken[] calldata oTokens,
        uint256[] calldata newSupplyCaps
    ) external {
        require(
            msg.sender == admin,
            "only admin"
        );

        uint256 numMarkets = oTokens.length;
        uint256 numSupplyCaps = newSupplyCaps.length;

        require(
            numMarkets != 0 && numMarkets == numSupplyCaps,
            "invalid input"
        );

        for (uint256 i = 0; i < numMarkets; i++) {
            supplyCaps[address(oTokens[i])] = newSupplyCaps[i];
            emit NewSupplyCap(oTokens[i], newSupplyCaps[i]);
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
            "only guardian/admin"
        );
    }

    function _setMintPaused(IOToken oToken, bool state) public returns (bool) {
        require(
            markets[address(oToken)].isListed,
            "cannot pause: not listed"
        );
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin");

        guardianPaused[address(oToken)].mint = state;
        emit ActionPaused(oToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(
        IOToken oToken,
        bool state
    ) public returns (bool) {
        require(
            markets[address(oToken)].isListed,
            "cannot pause: not listed"
        );
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin");

        guardianPaused[address(oToken)].borrow = state;
        emit ActionPaused(oToken, "Borrow", state);
        return state;
    }

    function _setRedeemPaused(
        IOToken oToken,
        bool state
    ) public returns (bool) {
        require(
            markets[address(oToken)].isListed,
            "cannot pause: not listed"
        );
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin");

        guardianPaused[address(oToken)].redeem = state;
        emit ActionPaused(oToken, "Redeem", state);
        return state;
    }

    function _setRepayPaused(
        IOToken oToken,
        bool state
    ) public returns (bool) {
        require(
            markets[address(oToken)].isListed,
            "cannot pause: not listed"
        );
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin");

        guardianPaused[address(oToken)].repay = state;
        emit ActionPaused(oToken, "Repay", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin");

        transferGuardianPaused = state;
        emit ActionPausedGlobally("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        onlyAdminOrGuardian();
        require(msg.sender == admin || state, "only admin");

        seizeGuardianPaused = state;
        emit ActionPausedGlobally("Seize", state);
        return state;
    }

    function _become(IUnitroller unitroller) public {
        require(
            msg.sender == unitroller.admin(),
            "only unitroller admin"
        );
        require(
            unitroller._acceptImplementation() == 0,
            "not authorized"
        );
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** VIX Distribution ***/

    /**
     * @notice Set Reward speed for a single market
     * @param oToken The market whose Reward speed to update
     * @param supplySpeed New supply-side Reward speed for market
     * @param borrowSpeed New borrow-side Reward speed for market
     */
    function setRewardSpeedInternal(
        IOToken oToken,
        uint256 supplySpeed,
        uint256 borrowSpeed
    ) internal {
        require(markets[address(oToken)].isListed, "not listed");

        if (rewardSupplySpeeds[address(oToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. Reward accrued properly for the old speed, and
            //  2. Reward accrued at the new speed starts after this block.
            updateRewardSupplyIndex(address(oToken));

            // Update speed and emit event
            rewardSupplySpeeds[address(oToken)] = supplySpeed;
            emit RewardSupplySpeedUpdated(oToken, supplySpeed);
        }

        if (rewardBorrowSpeeds[address(oToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. Reward accrued properly for the old speed, and
            //  2. Reward accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({ mantissa: oToken.borrowIndex() });
            updateRewardBorrowIndex(address(oToken), borrowIndex);

            // Update speed and emit event
            rewardBorrowSpeeds[address(oToken)] = borrowSpeed;
            emit RewardBorrowSpeedUpdated(oToken, borrowSpeed);
        }
    }

    function updateAndDistributeSupplierRewardsForToken(
        address oToken,
        address account
    ) public override {
        updateRewardSupplyIndex(oToken);
        distributeSupplierReward(oToken, account);
    }

    function updateAndDistributeBorrowerRewardsForToken(
        address oToken,
        address borrower
    ) public override {
        Exp memory marketBorrowIndex = Exp({
            mantissa: IOToken(oToken).borrowIndex()
        });
        updateRewardBorrowIndex(oToken, marketBorrowIndex);
        distributeBorrowerReward(oToken, borrower, marketBorrowIndex);
    }

    /**
     * @notice Accrue Reward to the market by updating the supply index
     * @param oToken The market whose supply index to update
     * @dev Index is a cumulative sum of the Reward per oToken accrued.
     */
    function updateRewardSupplyIndex(address oToken) internal {
        MarketState storage supplyState = supplyState[oToken];
        uint256 supplySpeed = rewardSupplySpeeds[oToken];
        uint32 timestamp = safe32(getTimestamp());
        uint256 deltaTimestamps = uint256(timestamp) -
            uint256(supplyState.timestamp);
        if (deltaTimestamps > 0) {
            if (supplySpeed > 0) {
                uint256 supplyTokens = address(boostManager) == address(0)
                    ? IOToken(oToken).totalSupply()
                    : boostManager.boostedTotalSupply(oToken);
                uint256 rewardAccrued = deltaTimestamps * supplySpeed;
                Double memory ratio = supplyTokens > 0
                    ? fraction(rewardAccrued, supplyTokens)
                    : Double({mantissa: 0});
                supplyState.index = safe224(
                    add_(Double({mantissa: supplyState.index}), ratio).mantissa
                );
            }
            supplyState.timestamp = timestamp;
        }
    }

    /**
     * @notice Accrue Reward to the market by updating the borrow index
     * @param oToken The market whose borrow index to update
     * @dev Index is a cumulative sum of the Reward per oToken accrued.
     */
    function updateRewardBorrowIndex(
        address oToken,
        Exp memory marketBorrowIndex
    ) internal {
        MarketState storage borrowState = borrowState[oToken];
        uint256 borrowSpeed = rewardBorrowSpeeds[oToken];
        uint32 timestamp = safe32(getTimestamp());
        uint256 deltaTimestamps = uint256(timestamp) -
            uint256(borrowState.timestamp);
        if (deltaTimestamps > 0) {
            if (borrowSpeed > 0) {
                uint256 borrowAmount = div_(
                    address(boostManager) == address(0)
                        ? IOToken(oToken).totalBorrows()
                        : boostManager.boostedTotalBorrows(oToken),
                    marketBorrowIndex
                );
                uint256 rewardAccrued = deltaTimestamps * borrowSpeed;
                Double memory ratio = borrowAmount > 0
                    ? fraction(rewardAccrued, borrowAmount)
                    : Double({mantissa: 0});
                borrowState.index = safe224(
                    add_(Double({mantissa: borrowState.index}), ratio).mantissa
                );
            }
            borrowState.timestamp = timestamp;
        }
    }

    /**
     * @notice Calculate Reward accrued by a supplier
     * @param oToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute Reward to
     */
    function distributeSupplierReward(address oToken, address supplier)
        internal
    {
        // TODO: Don't distribute supplier Reward if the user is not in the supplier market.
        // This check should be as gas efficient as possible as distributeSupplierReward is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        uint256 supplyIndex = supplyState[oToken].index;
        uint256 supplierIndex = rewardSupplierIndex[oToken][supplier];

        // Update supplier's index to the current index since we are distributing accrued VIX
        rewardSupplierIndex[oToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= 0) {
            return;
        }

        // Calculate change in the cumulative sum of the Reward per oToken accrued
        Double memory deltaIndex = Double({
            mantissa: supplyIndex - supplierIndex
        });

        uint256 supplierTokens = address(boostManager) == address(0)
            ? IOToken(oToken).balanceOf(supplier)
            : boostManager.boostedSupplyBalanceOf(oToken, supplier);

        if (supplyIndex != supplierIndex) {
            // Calculate Reward accrued: oTokenAmount * accruedPerOToken
            uint256 supplierDelta = mul_(supplierTokens, deltaIndex);

            uint256 supplierAccrued = rewardAccrued[supplier] + supplierDelta;
            rewardAccrued[supplier] = supplierAccrued;

            emit DistributedSupplierReward(
                IOToken(oToken),
                supplier,
                supplierDelta,
                supplyIndex
            );
        }
    }

    /**
     * @notice Calculate Reward accrued by a borrower
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param oToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute Reward to
     */
    function distributeBorrowerReward(
        address oToken,
        address borrower,
        Exp memory marketBorrowIndex
    ) internal {
        // TODO: Don't distribute supplier Reward if the user is not in the borrower market.
        // This check should be as gas efficient as possible as distributeBorrowerReward is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        uint256 borrowIndex = borrowState[oToken].index;
        uint256 borrowerIndex = rewardBorrowerIndex[oToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued VIX
        rewardBorrowerIndex[oToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= 0) {
            return;
        }

        // Calculate change in the cumulative sum of the Reward per borrowed unit accrued
        Double memory deltaIndex = Double({
            mantissa: borrowIndex - borrowerIndex
        });

        if (borrowIndex != borrowerIndex) {
            uint256 borrowerAmount = div_(
                address(boostManager) == address(0)
                    ? IOToken(oToken).borrowBalanceStored(borrower)
                    : boostManager.boostedBorrowBalanceOf(oToken, borrower),
                marketBorrowIndex
            );

            // Calculate Reward accrued: oTokenAmount * accruedPerBorrowedUnit
            uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);

            uint256 borrowerAccrued = rewardAccrued[borrower] + borrowerDelta;
            rewardAccrued[borrower] = borrowerAccrued;

            emit DistributedBorrowerReward(
                IOToken(oToken),
                borrower,
                borrowerDelta,
                borrowIndex
            );
        }
    }

    /**
     * @notice Calculate additional accrued Reward for a contributor since last accrual
     * @param contributor The address to calculate contributor rewards for
     */
    function updateContributorRewards(address contributor) public {
        uint256 rewardSpeed = rewardContributorSpeeds[contributor];
        uint256 timestamp = getTimestamp();
        uint256 deltaTimestamps = timestamp - lastContributorTimestamp[contributor];
        if (deltaTimestamps > 0 && rewardSpeed > 0) {
            uint256 newAccrued = deltaTimestamps * rewardSpeed;
            uint256 contributorAccrued = rewardAccrued[contributor] +
                newAccrued;

            rewardAccrued[contributor] = contributorAccrued;
            lastContributorTimestamp[contributor] = timestamp;
        }
    }

    // /**
    //  * @notice Claim all the reward accrued by holder in all markets
    //  * @param holder The address to claim Reward for
    //  */

    // function claimReward(address holder) public returns (uint256) {
    //     address[] memory holders = new address[](1);
    //     holders[0] = holder;
    //     claimRewards(holders, allMarkets, true, true);
        
    //     uint256 totalReward = rewardAccrued[holder];
    //     rewardAccrued[holder] = grantRewardInternal(holder, totalReward);
    //     return totalReward;
    // }

    // /**
    //  * @notice Claim all the reward accrued by holder in the specified markets
    //  * @param holder The address to claim Reward for
    //  * @param oTokens The list of markets to claim Reward in
    //  */
    // function claimRewards(address holder, IOToken[] memory oTokens) public {
    //     address[] memory holders = new address[](1);
    //     holders[0] = holder;
    //     claimRewards(holders, oTokens, true, true);
    // }

    /**
     * @notice Claim all reward accrued by the holders
     * @param holders The addresses to claim Reward for
     * @param oTokens The list of markets to claim Reward in
     */
    function claimRewards(
        address[] memory holders,
        IOToken[] memory oTokens,
        bool,
        bool
    ) public {
        uint256 oTokenLength = oTokens.length;
        uint256 holdersLength = holders.length;
        for (uint256 i; i < oTokenLength;) {
            require(markets[address(oTokens[i])].isListed, "must be listed");
            for (uint256 j; j < holdersLength;) {
                updateAndDistributeSupplierRewardsForToken(address(oTokens[i]), holders[j]);
                updateAndDistributeBorrowerRewardsForToken(address(oTokens[i]), holders[j]);
                unchecked {++j;}
            }
            unchecked {++i;}
        }
        for (uint256 j; j < holdersLength;) {
            rewardAccrued[holders[j]] = grantRewardInternal(
                holders[j],
                rewardAccrued[holders[j]]
            );
            unchecked {++j;}
        }
    }

    /**
     * @notice Transfer Reward to the user
     * @dev Note: If there is not enough VIX, we do not perform the transfer all.
     * @param user The address of the user to transfer Reward to
     * @param amount The amount of Reward to (possibly) transfer
     * @return The amount of Reward which was NOT transferred to the user
     */
    function grantRewardInternal(address user, uint256 amount)
        internal
        returns (uint256)
    {
        I0vix vix = I0vix(getVixAddress());
        if (address(vix) != address(0)) {
            uint256 rewardRemaining = vix.balanceOf(address(this));
            if (amount > 0 && amount <= rewardRemaining) {
                vix.transfer(user, amount);
                emit VixClaimed(user, amount);
                return 0;
            }
        }

        return amount;
    }

    /*** VIX Distribution Admin ***/

    /**
     * @notice Transfer Reward to the recipient
     * @dev Note: If there is not enough VIX, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer Reward to
     * @param amount The amount of Reward to (possibly) transfer
     */
    function _grantReward(address recipient, uint256 amount) public {
        require(adminOrInitializing(), "only admin");
        uint256 amountLeft = grantRewardInternal(recipient, amount);
        require(amountLeft == 0, "insufficient token for grant");
        emit VixGranted(recipient, amount);
    }

    /**
     * @notice Set Reward borrow and supply speeds for the specified markets.
     * @param oTokens The markets whose Reward speed to update.
     * @param supplySpeeds New supply-side Reward speed for the corresponding market.
     * @param borrowSpeeds New borrow-side Reward speed for the corresponding market.
     */
    function _setRewardSpeeds(
        address[] memory oTokens,
        uint256[] memory supplySpeeds,
        uint256[] memory borrowSpeeds
    ) public override {
        require(
            msg.sender == admin || msg.sender == rewardUpdater,
            "only admin"
        );

        uint256 numTokens = oTokens.length;
        require(
            numTokens == supplySpeeds.length &&
                numTokens == borrowSpeeds.length,
            "invalid input"
        );

        for (uint256 i; i < numTokens;) {
            setRewardSpeedInternal(
                IOToken(oTokens[i]),
                supplySpeeds[i],
                borrowSpeeds[i]
            );
            unchecked { ++i;}
        }
    }

    // /**
    // * @notice Set Reward speed for a single contributor
    // * @param contributor The contributor whose Reward speed to update
    // * @param rewardSpeed New Reward speed for contributor
    // */
    // function _setContributorRewardSpeed(
    // address contributor,
    // uint256 rewardSpeed
    // ) public {
    // require(
    // msg.sender == admin || msg.sender == rewardUpdater,
    // "only admin can set reward speed"
    //     );

    // // note that Reward speed could be set to 0 to halt liquidity rewards for a contributor
    // updateContributorRewards(contributor);
    // if (rewardSpeed == 0) {
    // // release storage
    // delete lastContributorTimestamp[contributor];
    // } else {
    // lastContributorTimestamp[contributor] = getTimestamp();
    // }
    //     rewardContributorSpeeds[contributor] = rewardSpeed;

    // emit ContributorRewardSpeedUpdated(contributor, rewardSpeed);
    // }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view override returns (IOToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Returns true if the given oToken market has been deprecated
     * @dev All borrows in a deprecated oToken market can be immediately liquidated
     * @param oToken The market to check if deprecated
     */
    function isDeprecated(IOToken oToken) public view returns (bool) {
        return
            markets[address(oToken)].collateralFactorMantissa == 0 &&
            guardianPaused[address(oToken)].borrow &&
            oToken.reserveFactorMantissa() == 1e18;
    }

    function getTimestamp() public view returns (uint256) {
        return block.timestamp;
    }

    /**
     * @notice Return the address of the 0VIX token
     * @return The address of VIX
     */
    function getVixAddress() public view returns (address) {
        return vixAddress;
    }

    /**
     * @notice Set the 0VIX token address
     */
    function setVixAddress(address newVixAddress) public onlyAdmin {
        require(newVixAddress != address(0), "no zero address allowed");
        require(vixAddress == address(0), "VIX already set");
                vixAddress = newVixAddress;
    }

    /**
     * @notice Set the booster manager address
     */
    function setBoostManager(address newBoostManager) public onlyAdmin {
        require(newBoostManager != address(0), "no zero address allowed");
        require(address(boostManager) == address(0), "VIX already set");
                boostManager = IBoostManager(newBoostManager);
    }

    function getBoostManager() external view override returns (address) {
        return address(boostManager);
    }

    function setRewardUpdater(address _rewardUpdater) public onlyAdmin {
        require(_rewardUpdater != address(0), "zero address");
        rewardUpdater = _rewardUpdater;
    }

    function setAutoCollaterize(address market, bool flag) external onlyAdmin {
        markets[market].autoCollaterize = flag;
    }

    /**
     * Pause or unpause all protocol functionality
     * - Pause can be invoked by admin or pause guardian
     * - Unpause can be invoked by admin only
     */
    function setProtocolPaused(bool _paused) public {

        for (uint i; i < allMarkets.length;) {
            IOToken market = allMarkets[i];
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
