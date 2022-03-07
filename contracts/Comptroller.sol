pragma solidity 0.8.4;

import "./libraries/ErrorReporter.sol";
import "./libraries/ExponentialNoError.sol";
import "./interfaces/IComptroller.sol";
import "./ComptrollerStorage.sol";

interface IOvix {
  function transfer(address, uint256) external;
  function balanceOf(address) external view returns(uint256);
}

interface IUnitroller {
  function admin() external view returns(address);
  function _acceptImplementation() external returns (uint);
}

/**
 * @title 0VIX's Comptroller Contract
 * @author 0VIX
 */
contract Comptroller is ComptrollerStorage, IComptroller, ComptrollerErrorReporter, ExponentialNoError {
    /// @notice Emitted when an admin modifies a reward updater
    event RewardUpdaterModified(address _rewardUpdater);

    /// @notice Emitted when an admin supports a market
    event MarketListed(IOToken oToken);

    /// @notice Emitted when an admin removes a market
    event MarketRemoved(IOToken oToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(IOToken oToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(IOToken oToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(IOToken oToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(IOToken oToken, string action, bool pauseState);

    /// @notice Emitted when a new 0VIX or MATIC speed is calculated for a market
    event SpeedUpdated(uint8 tokenType, IOToken indexed oToken, uint newSpeed);

    /// @notice Emitted when a new 0VIX speed is set for a contributor
    event ContributorOSpeedUpdated(address indexed contributor, uint newSpeed);

    /// @notice Emitted when 0VIX or MATIC is distributed to a borrower
    event DistributedBorrowerReward(uint8 indexed tokenType, IOToken indexed oToken, address indexed borrower, uint oDelta, uint oBorrowIndex);

    /// @notice Emitted when 0VIX or MATIC is distributed to a supplier
    event DistributedSupplierReward(uint8 indexed tokenType, IOToken indexed oToken, address indexed borrower, uint oDelta, uint oBorrowIndex);

    /// @notice Emitted when borrow cap for a oToken is changed
    event NewBorrowCap(IOToken indexed oToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice Emitted when 0VIX is granted by admin
    event OGranted(address recipient, uint amount);

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    bool public constant override isComptroller = true;

    /// @notice The initial 0VIX and MATIC index for a market
    uint224 public constant initialIndexConstant = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    // reward token type to show 0VIX or MATIC
    uint8 public constant rewardOvix = 0;
    uint8 public constant rewardMatic = 1;

    address public rewardUpdater;
    
    constructor() {
        admin = msg.sender;
        rewardUpdater = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (IOToken[] memory) {
        return accountAssets[account];
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param oToken The oToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, IOToken oToken) external view returns (bool) {
        return accountMembership[address(oToken)][account];
    }

    /**
     * @notice Returns whether the given token is listed market
     * @param oToken The oToken to check
     * @return True if is market, otherwise false.
     */
    function isMarket(address oToken) external view override returns(bool) {
        return markets[oToken].isListed;
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param oTokens The list of addresses of the oToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory oTokens) public override returns (uint[] memory) {
        uint len = oTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            results[i] = uint(addToMarketInternal(IOToken(oTokens[i]), msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param oToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(IOToken oToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(oToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (accountMembership[address(oToken)][borrower] == true) {
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
    function exitMarket(address oTokenAddress) external override returns (uint) {
        IOToken oToken = IOToken(oTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the oToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = oToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(oTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(oToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!accountMembership[address(oToken)][msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set oToken account membership to false */
        delete accountMembership[address(oToken)][msg.sender];

        /* Delete oToken from the account’s list of assets */
        // load into memory for faster iteration
        IOToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
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

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param oToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address oToken, address minter, uint mintAmount) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!guardianPaused[oToken].mint, "mint paused");

        // Shh - currently unused
        mintAmount;

        if (!markets[oToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(oToken, minter);
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param oToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address oToken, address minter, uint actualMintAmount, uint mintTokens) external override {
        // Shh - currently unused
        oToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param oToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of oTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address oToken, address redeemer, uint redeemTokens) external override returns (uint) {
        uint allowed = redeemAllowedInternal(oToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(oToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address oToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[oToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!accountMembership[oToken][redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, IOToken(oToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param oToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address oToken, address redeemer, uint redeemAmount, uint redeemTokens) external override {
        // Shh - currently unused
        oToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param oToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address oToken, address borrower, uint borrowAmount) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!guardianPaused[oToken].borrow, "borrow  paused");

        if (!markets[oToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!accountMembership[oToken][borrower]) {
            // only oTokens may call borrowAllowed if borrower not in market
            require(msg.sender == oToken, "sender not oToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(IOToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(accountMembership[oToken][borrower]);
        }

        if (oracle.getUnderlyingPrice(IOToken(oToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }


        uint borrowCap = borrowCaps[oToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            // uint totalBorrows = IOToken(oToken).totalBorrows();
            // uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(add_(IOToken(oToken).totalBorrows(), borrowAmount) < borrowCap, "borrow cap reached");
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, IOToken(oToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        updateAndDistributeBorrowerRewardsForToken(oToken, borrower);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param oToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address oToken, address borrower, uint borrowAmount) external override {
        // Shh - currently unused
        oToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
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
        uint repayAmount) external override returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[oToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateAndDistributeBorrowerRewardsForToken(oToken, borrower);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
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
        uint repayAmount) external override returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[oTokenBorrowed].isListed || !markets[oTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, IOToken(address(0)), 0, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), IOToken(oTokenBorrowed).borrowBalanceStored(borrower));
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
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
        uint seizeTokens) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[oTokenCollateral].isListed || !markets[oTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (IOToken(oTokenCollateral).comptroller() != IOToken(oTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(oTokenCollateral, borrower);
        updateAndDistributeSupplierRewardsForToken(oTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param oTokenCollateral Asset which was used as collateral and will be seized
     * @param oTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address oTokenCollateral,
        address oTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) external override {
        // Shh - currently unused
        oTokenCollateral;
        oTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param oToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of oTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address oToken, address src, address dst, uint transferTokens) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(oToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateAndDistributeSupplierRewardsForToken(oToken, src);
        updateAndDistributeSupplierRewardsForToken(oToken, dst);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param oToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of oTokens to transfer
     */
    function transferVerify(address oToken, address src, address dst, uint transferTokens) external override {
        // Shh - currently unused
        oToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `oTokenBalance` is the number of oTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint oTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
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
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, IOToken(address(0)), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param oTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address oTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, IOToken(oTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
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
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        IOToken oTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds calculation vars
        uint oErr;

        // For each asset the account is in
        IOToken[] memory assets = accountAssets[account];

        uint256 sumCollateral;
        uint256 sumBorrowPlusEffects;

        for (uint i = 0; i < assets.length; i++) {
            IOToken asset = assets[i];
            // Read the balances and exchange rate from the oToken
            (oErr, vars.oTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            uint256 oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> avax (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * oTokenBalance
            sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.oTokenBalance, sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, sumBorrowPlusEffects);

            // Calculate effects of interacting with oTokenModify
            if (asset == oTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (sumCollateral > sumBorrowPlusEffects) {
            return (Error.NO_ERROR, sumCollateral - sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, sumBorrowPlusEffects - sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in oToken.liquidateBorrowFresh)
     * @param oTokenBorrowed The address of the borrowed oToken
     * @param oTokenCollateral The address of the collateral oToken
     * @param actualRepayAmount The amount of oTokenBorrowed underlying to convert into oTokenCollateral tokens
     * @return (errorCode, number of oTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address oTokenBorrowed, address oTokenCollateral, uint actualRepayAmount) external override view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(IOToken(oTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(IOToken(oTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = IOToken(oTokenCollateral).exchangeRateStored(); // Note: reverts on error
        
        Exp memory numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        Exp memory denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));

        uint seizeTokens = mul_ScalarTruncate(div_(numerator, denominator), actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the comptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external onlyAdmin returns (uint) {
        // Check caller is admin
    	//require(msg.sender == admin, "only admin");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param oToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(IOToken oToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(oToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(oToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(oToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param oToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(IOToken oToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(oToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        oToken.isOToken(); // Sanity check to make sure its really a IOToken

        // Note that isOed is not in active use anymore
        markets[address(oToken)] = Market({isListed: true, isOed: false, collateralFactorMantissa: 0});

        _addMarketInternal(address(oToken));

        emit MarketListed(oToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address oToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != IOToken(oToken), "market already added");
        }
        allMarkets.push(IOToken(oToken));
    }

    function _removeMarket(IOToken oToken) external onlyAdmin returns (uint256) {
        //require(msg.sender == admin);
        require(markets[address(oToken)].isListed);

        oToken.isOToken(); // Sanity check to make sure its really a CToken

        require(
            IOToken(oToken).totalBorrowsCurrent() == 0,
            "market has borrows"
        );

      require(IOToken(oToken).totalSupply() == 0, "market has supply");

       for (uint256 i = 0; i < allMarkets.length; i++) {
            if (allMarkets[i] == oToken) {
                allMarkets[i] = allMarkets[allMarkets.length - 1];
                allMarkets.pop();
                break;
            }
        }
        delete markets[address(oToken)];

        emit MarketRemoved(oToken);
        return uint256(Error.NO_ERROR);
    }


    /**
      * @notice Set the given borrow caps for the given oToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
      * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
      * @param oTokens The addresses of the markets (tokens) to change the borrow caps for
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketBorrowCaps(IOToken[] calldata oTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or borrow cap guard"); 

        uint numMarkets = oTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(oTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(oTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) onlyAdmin external {
        //require(msg.sender == admin, "only admin or borrow cap guard");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function onlyAdminOrGuardian(bool state) internal view {
        require(msg.sender == admin || (msg.sender == pauseGuardian && state), "only pause guardian and admin");
    }

    function _setMintPaused(IOToken oToken, bool state) public returns (bool) {
        require(markets[address(oToken)].isListed, "market not listed");
        onlyAdminOrGuardian(state);
        guardianPaused[address(oToken)].mint = state;
        emit ActionPaused(oToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(IOToken oToken, bool state) public returns (bool) {
        require(markets[address(oToken)].isListed, "market not listed");
        onlyAdminOrGuardian(state);
        guardianPaused[address(oToken)].borrow = state;
        emit ActionPaused(oToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        onlyAdminOrGuardian(state);
        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        onlyAdminOrGuardian(state);
        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(IUnitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** 0VIX Distribution ***/

    /**
     * @notice Set 0VIX/MATIC speed for a single market
     * @param rewardType  0: O, 1: Matic
     * @param oToken The market whose 0VIX speed to update
     * @param newSpeed New 0VIX or MATIC speed for market
     */
    function setRewardSpeedInternal(uint8 rewardType, IOToken oToken, uint newSpeed) internal {
        uint currentRewardSpeed = rewardSpeeds[rewardType][address(oToken)];
        if (currentRewardSpeed != 0) {
            // note that 0VIX speed could be set to 0 to halt liquidity rewards for a market
            Exp memory borrowIndex = Exp({mantissa: oToken.borrowIndex()});
            updateRewardSupplyIndex(rewardType,address(oToken));
            updateRewardBorrowIndex(rewardType,address(oToken), borrowIndex);
        } else if (newSpeed != 0) {
            // Add the 0VIX market
            Market storage market = markets[address(oToken)];
            require(market.isListed == true, "ovix market is not listed");

            if (rewardSupplyState[rewardType][address(oToken)].index == 0 && rewardSupplyState[rewardType][address(oToken)].timestamp == 0) {
                rewardSupplyState[rewardType][address(oToken)] = RewardMarketState({
                    index: initialIndexConstant,
                    timestamp: safe32(getBlockTimestamp(), "block timestamp exceeds 32 bits")
                });
            }

            if (rewardBorrowState[rewardType][address(oToken)].index == 0 && rewardBorrowState[rewardType][address(oToken)].timestamp == 0) {
                rewardBorrowState[rewardType][address(oToken)] = RewardMarketState({
                    index: initialIndexConstant,
                    timestamp: safe32(getBlockTimestamp(), "block timestamp exceeds 32 bits")
                });
            }
        }

        if (currentRewardSpeed != newSpeed) {
            rewardSpeeds[rewardType][address(oToken)] = newSpeed;
            emit SpeedUpdated(rewardType, oToken, newSpeed);
        }
    }

    /**
     * @notice Accrue 0VIX to the market by updating the supply index
     * @param rewardType  0: O, 1: Matic
     * @param oToken The market whose supply index to update
     */
    function updateRewardSupplyIndex(uint8 rewardType, address oToken) internal {
        require(rewardType <= 1, "rewardType is invalid"); 
        RewardMarketState storage supplyState = rewardSupplyState[rewardType][oToken];
        uint supplySpeed = rewardSpeeds[rewardType][oToken];
        uint blockTimestamp = getBlockTimestamp();
        uint deltaTimestamps = sub_(blockTimestamp, uint(supplyState.timestamp));
        if (deltaTimestamps > 0) {
            if (supplySpeed > 0) {
                //uint supplyTokens = IOToken(oToken).totalSupply();
                uint supplyTokens = boostManager.boostedTotalSupply(oToken);
                uint oAccrued = mul_(deltaTimestamps, supplySpeed);
                //Double memory ratio = supplyTokens > 0 ? fraction(oAccrued, supplyTokens) : Double({mantissa: 0});
                Double memory index = add_(
                    Double({mantissa: supplyState.index}), 
                    supplyTokens > 0 ? fraction(oAccrued, supplyTokens) : Double({mantissa: 0})
                );
                rewardSupplyState[rewardType][oToken] = RewardMarketState({
                    index: safe224(index.mantissa, "new index exceeds 224 bits"),
                    timestamp: safe32(blockTimestamp, "block timestamp exceeds 32 bits")
                });
            } else {
                supplyState.timestamp = safe32(blockTimestamp, "block timestamp exceeds 32 bits");
            }
        }
    }

    /**
     * @notice Accrue 0VIX to the market by updating the borrow index
     * @param rewardType  0: O, 1: Matic
     * @param oToken The market whose borrow index to update
     */
    function updateRewardBorrowIndex(uint8 rewardType, address oToken, Exp memory marketBorrowIndex) internal {
        require(rewardType <= 1, "rewardType is invalid"); 
        RewardMarketState storage borrowState = rewardBorrowState[rewardType][oToken];
        uint borrowSpeed = rewardSpeeds[rewardType][oToken];
        uint blockTimestamp = getBlockTimestamp();
        uint deltaTimestamps = sub_(blockTimestamp, uint(borrowState.timestamp));
        if (deltaTimestamps > 0) {
            if (borrowSpeed > 0) {
                //uint borrowAmount = div_(IOToken(oToken).totalBorrows(), marketBorrowIndex);
                uint borrowAmount = div_(boostManager.boostedTotalBorrows(oToken), marketBorrowIndex);
                uint oAccrued = mul_(deltaTimestamps, borrowSpeed);
                Double memory index = add_(
                    Double({mantissa: borrowState.index}), 
                    borrowAmount > 0 ? fraction(oAccrued, borrowAmount) : Double({mantissa: 0})
                );
                rewardBorrowState[rewardType][oToken] = RewardMarketState({
                    index: safe224(index.mantissa, "new index exceeds 224 bits"),
                    timestamp: safe32(blockTimestamp, "block timestamp exceeds 32 bits")
                });
            } else {
                borrowState.timestamp = safe32(blockTimestamp, "block timestamp exceeds 32 bits");
            }
        }
    }

    /**
     * @notice Refactored function to calc and rewards accounts supplier rewards
     * @param oToken The market to verify the mint against
     * @param account The acount to whom 0VIX or MATIC is rewarded
     */
    function updateAndDistributeSupplierRewardsForToken(address oToken, address account) public override {
        for (uint8 rewardType = 0; rewardType <= 1; rewardType++) {
            updateRewardSupplyIndex(rewardType, oToken);
            distributeSupplierReward(rewardType, oToken, account);
        }
    }

    /**
     * @notice Calculate 0VIX/MATIC accrued by a supplier and possibly transfer it to them
     * @param rewardType  0: O, 1: Matic
     * @param oToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute 0VIX to
     */
    function distributeSupplierReward(uint8 rewardType, address oToken, address supplier) internal {
        require(rewardType <= 1, "rewardType is invalid"); 
        RewardMarketState storage supplyState = rewardSupplyState[rewardType][oToken];
        Double memory supplyIndex = Double({mantissa: supplyState.index});
        Double memory supplierIndex = Double({mantissa: rewardSupplierIndex[rewardType][oToken][supplier]});
        rewardSupplierIndex[rewardType][oToken][supplier] = supplyIndex.mantissa;

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = initialIndexConstant;
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        //uint supplierTokens = IOToken(oToken).balanceOf(supplier);
        uint supplierTokens = boostManager.boostedSupplyBalanceOf(oToken, supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(rewardAccrued[rewardType][supplier], supplierDelta);
        rewardAccrued[rewardType][supplier] = supplierAccrued;
        emit DistributedSupplierReward(rewardType, IOToken(oToken), supplier, supplierDelta, supplyIndex.mantissa);
    }

   /**
     * @notice Refactored function to calc and rewards accounts supplier rewards
     * @param oToken The market to verify the mint against
     * @param borrower Borrower to be rewarded
     */
    function updateAndDistributeBorrowerRewardsForToken(address oToken, address borrower) public override {
        Exp memory marketBorrowIndex = Exp({mantissa: IOToken(oToken).borrowIndex()});
        for (uint8 rewardType = 0; rewardType <= 1; rewardType++) {
            updateRewardBorrowIndex(rewardType, oToken, marketBorrowIndex);
            distributeBorrowerReward(rewardType, oToken, borrower, marketBorrowIndex);
        }
    }

    /**
     * @notice Calculate 0VIX accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param rewardType  0: O, 1: Matic
     * @param oToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute 0VIX to
     */
    function distributeBorrowerReward(uint8 rewardType, address oToken, address borrower, Exp memory marketBorrowIndex) internal {
        require(rewardType <= 1, "rewardType is invalid"); 
        RewardMarketState storage borrowState = rewardBorrowState[rewardType][oToken];
        Double memory borrowIndex = Double({mantissa: borrowState.index});
        Double memory borrowerIndex = Double({mantissa: rewardBorrowerIndex[rewardType][oToken][borrower]});
        rewardBorrowerIndex[rewardType][oToken][borrower] = borrowIndex.mantissa;

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            //uint borrowerAmount = div_(IOToken(oToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerAmount = div_(boostManager.boostedBorrowBalanceOf(oToken, borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint borrowerAccrued = add_(rewardAccrued[rewardType][borrower], borrowerDelta);
            rewardAccrued[rewardType][borrower] = borrowerAccrued;
            emit DistributedBorrowerReward(rewardType, IOToken(oToken), borrower, borrowerDelta, borrowIndex.mantissa);
        }
    }

    /**
     * @notice Claim all the ovix accrued by holder in all markets
     * @param holder The address to claim 0VIX for
     */
    function claimReward(uint8 rewardType, address payable holder) public returns(uint256 rewardAmount) {
        //return claimReward(rewardType, holder, allMarkets);
        require(rewardType <= 1, "rewardType is invalid");
        for (uint i = 0; i < allMarkets.length; i++) {
            IOToken oToken = allMarkets[i];
            //require(markets[address(oToken)].isListed, "market must be listed");  DEV: as i understand, we can trust allMarkets

            Exp memory borrowIndex = Exp({mantissa: oToken.borrowIndex()});
            updateRewardBorrowIndex(rewardType,address(oToken), borrowIndex);
            distributeBorrowerReward(rewardType,address(oToken), holder, borrowIndex);
            
            updateRewardSupplyIndex(rewardType,address(oToken));
            distributeSupplierReward(rewardType,address(oToken), holder);

            rewardAmount += rewardAccrued[rewardType][holder];
            rewardAccrued[rewardType][holder] = grantRewardInternal(rewardType, holder, rewardAccrued[rewardType][holder]);
        }
    }

    /**
     * @notice Claim all the ovix accrued by holder in the specified markets
     * @param holder The address to claim 0VIX for
     * @param oTokens The list of markets to claim 0VIX in
     */
    function claimReward(uint8 rewardType, address payable holder, IOToken[] memory oTokens) public {
        address payable [] memory holders = new address payable[](1);
        holders[0] = holder;
        claimReward(rewardType, holders, oTokens, true, true);
    }

    /**
     * @notice Claim all 0VIX or Matic  accrued by the holders
     * @param rewardType  0 means Ovix   1 means Matic
     * @param holders The addresses to claim MATIC for
     * @param oTokens The list of markets to claim MATIC in
     * @param borrowers Whether or not to claim MATIC earned by borrowing
     * @param suppliers Whether or not to claim MATIC earned by supplying
     */
    function claimReward(uint8 rewardType, address payable[] memory holders, IOToken[] memory oTokens, bool borrowers, bool suppliers) public payable {
        require(rewardType <= 1, "rewardType invalid");
        for (uint i = 0; i < oTokens.length; i++) {
            IOToken oToken = oTokens[i];
            require(markets[address(oToken)].isListed, "market not listed");
            if (borrowers) {
                Exp memory borrowIndex = Exp({mantissa: oToken.borrowIndex()});
                updateRewardBorrowIndex(rewardType,address(oToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrowerReward(rewardType,address(oToken), holders[j], borrowIndex);
                    rewardAccrued[rewardType][holders[j]] = grantRewardInternal(rewardType, holders[j], rewardAccrued[rewardType][holders[j]]);
                }
            }
            if (suppliers) {
                updateRewardSupplyIndex(rewardType,address(oToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierReward(rewardType,address(oToken), holders[j]);
                    rewardAccrued[rewardType][holders[j]] = grantRewardInternal(rewardType, holders[j], rewardAccrued[rewardType][holders[j]]);
                }
            }
        }
    }

    /**
     * @notice Transfer O/MATIC to the user
     * @dev Note: If there is not enough 0VIX/MATIC, we do not perform the transfer all.
     * @param user The address of the user to transfer MATIC to
     * @param amount The amount of MATIC to (possibly) transfer
     * @return The amount of MATIC which was NOT transferred to the user
     */
    function grantRewardInternal(uint rewardType, address payable user, uint amount) internal returns (uint) {
        if (amount > 0) {
            if (rewardType == 0) {
                IOvix ovix = IOvix(oAddress);
                if (amount <= ovix.balanceOf(address(this))) {
                    ovix.transfer(user, amount);
                    return 0;
                }
            } else if (rewardType == 1) {
                if (amount <= address(this).balance) {
                    user.transfer(amount);
                    return 0;
                }
            }
        }
        return amount;
    }

    /*** 0VIX Distribution Admin ***/

    /**
     * @notice Transfer 0VIX to the recipient
     * @dev Note: If there is not enough 0VIX, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer 0VIX to
     * @param amount The amount of 0VIX to (possibly) transfer
     */
    function _grantOvix(address payable recipient, uint amount) public {
        require(adminOrInitializing(), "only admin can grant ovix");
        //uint amountLeft = grantRewardInternal(0, recipient, amount);
        require(grantRewardInternal(0, recipient, amount) == 0, "insufficient ovix for grant");
        emit OGranted(recipient, amount);
    }

    /**
     * @notice Set reward speed for a single market
     * @param rewardType 0 = O, 1 = MATIC
     * @param oToken The market whose reward speed to update
     * @param rewardSpeed New reward speed for market
     */
    function _setRewardSpeed(uint8 rewardType, address oToken, uint rewardSpeed) public override {
        require(rewardType <= 1, "rewardType is invalid"); 
        require(adminOrInitializing() || msg.sender == rewardUpdater, "only admin");
        setRewardSpeedInternal(rewardType, IOToken(oToken), rewardSpeed);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view override returns (IOToken[] memory) {
        return allMarkets;
    }

    function getBlockTimestamp() public view returns (uint) {
        return block.timestamp;
    }

    /**
     * @notice Set the Ovix token address
     */
    function setOAddress(address newOAddress) public onlyAdmin {
        oAddress = newOAddress;
    }

    /**
     * @notice Set the booster manager address
     */
    function setBoostManager(address newBoostManager) public onlyAdmin {
        boostManager = IBoostManager(newBoostManager);
    }

    function getBoostManager() external view override returns(address) {
        return address(boostManager);
    }

    /**
     * @notice set reward updater address
     */
    function setRewardUpdater(address _rewardUpdater) public onlyAdmin {
        rewardUpdater = _rewardUpdater;
        emit RewardUpdaterModified(_rewardUpdater);
    }

    /**
     * @notice payable function needed to receive MATIC
     */
    receive() payable external {
    }
}
