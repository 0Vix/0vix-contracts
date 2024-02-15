//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../interfaces/IComptroller.sol";
import "../oracles/PriceOracle.sol";


contract BoolComptroller is IComptroller {
    PriceOracle public override oracle = PriceOracle(address(0));

    bool public constant override isComptroller = true;

    bool allowMint = true;
    bool allowRedeem = true;
    bool allowBorrow = true;
    bool allowRepayBorrow = true;
    bool allowLiquidateBorrow = true;
    bool allowSeize = true;
    bool allowTransfer = true;

    bool verifyMint = true;
    bool verifyRedeem = true;
    bool verifyBorrow = true;
    bool verifyRepayBorrow = true;
    bool verifyLiquidateBorrow = true;
    bool verifySeize = true;
    bool verifyTransfer = true;

    bool failCalculateSeizeTokens;
    uint calculatedSeizeTokens;

    uint noError = 0;
    uint opaqueError = noError + 11; // an arbitrary, opaque error code

    /*** Assets You Are In ***/

    function enterMarkets(
        address[] calldata _kTokens
    ) external override returns (uint[] memory) {
        _kTokens;
        uint[] memory ret;
        return ret;
    }

    function exitMarket(address _kToken) external override returns (uint) {
        _kToken;
        return noError;
    }

    /*** Policy Hooks ***/

    function mintAllowed(
        address _kToken,
        address _minter,
        uint _mintAmount
    ) public override returns (uint) {
        _kToken;
        _minter;
        _mintAmount;
        return allowMint ? noError : opaqueError;
    }

    function mintVerify(
        address _kToken,
        address _minter,
        uint _mintAmount,
        uint _mintTokens
    ) external {
        _kToken;
        _minter;
        _mintAmount;
        _mintTokens;
        require(verifyMint, "mintVerify rejected mint");
    }

    function redeemAllowed(
        address _kToken,
        address _redeemer,
        uint _redeemTokens
    ) public override returns (uint) {
        _kToken;
        _redeemer;
        _redeemTokens;
        return allowRedeem ? noError : opaqueError;
    }

    function redeemVerify(
        address _kToken,
        address _redeemer,
        uint _redeemAmount,
        uint _redeemTokens
    ) external override {
        _kToken;
        _redeemer;
        _redeemAmount;
        _redeemTokens;
        require(verifyRedeem, "redeemVerify rejected redeem");
    }

    function borrowAllowed(
        address _kToken,
        address _borrower,
        uint _borrowAmount
    ) public override returns (uint) {
        _kToken;
        _borrower;
        _borrowAmount;
        return allowBorrow ? noError : opaqueError;
    }

    function borrowVerify(
        address _kToken,
        address _borrower,
        uint _borrowAmount
    ) external {
        _kToken;
        _borrower;
        _borrowAmount;
        require(verifyBorrow, "borrowVerify rejected borrow");
    }

    function repayBorrowAllowed(
        address _kToken,
        address _payer,
        address _borrower,
        uint _repayAmount
    ) public override returns (uint) {
        _kToken;
        _payer;
        _borrower;
        _repayAmount;
        return allowRepayBorrow ? noError : opaqueError;
    }

    function repayBorrowVerify(
        address _kToken,
        address _payer,
        address _borrower,
        uint _repayAmount,
        uint _borrowerIndex
    ) external {
        _kToken;
        _payer;
        _borrower;
        _repayAmount;
        _borrowerIndex;
        require(verifyRepayBorrow, "repayBorrowVerify rejected repayBorrow");
    }

    function liquidateBorrowAllowed(
        address _kTokenBorrowed,
        address _kTokenCollateral,
        address _liquidator,
        address _borrower,
        uint _repayAmount
    ) public override returns (uint, uint) {
        _kTokenBorrowed;
        _kTokenCollateral;
        _liquidator;
        _borrower;
        _repayAmount;
        return allowLiquidateBorrow ? (noError, 11e17) : (opaqueError, 0);
    }

    function liquidateBorrowVerify(
        address _kTokenBorrowed,
        address _kTokenCollateral,
        address _liquidator,
        address _borrower,
        uint _repayAmount,
        uint _seizeTokens
    ) external {
        _kTokenBorrowed;
        _kTokenCollateral;
        _liquidator;
        _borrower;
        _repayAmount;
        _seizeTokens;
        require(
            verifyLiquidateBorrow,
            "liquidateBorrowVerify rejected liquidateBorrow"
        );
    }

    function seizeAllowed(
        address _kTokenCollateral,
        address _kTokenBorrowed,
        address _borrower,
        address _liquidator,
        uint _seizeTokens
    ) public override returns (uint) {
        _kTokenCollateral;
        _kTokenBorrowed;
        _liquidator;
        _borrower;
        _seizeTokens;
        return allowSeize ? noError : opaqueError;
    }

    function seizeVerify(
        address _kTokenCollateral,
        address _kTokenBorrowed,
        address _liquidator,
        address _borrower,
        uint _seizeTokens
    ) external {
        _kTokenCollateral;
        _kTokenBorrowed;
        _liquidator;
        _borrower;
        _seizeTokens;
        require(verifySeize, "seizeVerify rejected seize");
    }

    function transferAllowed(
        address _kToken,
        address _src,
        address _dst,
        uint _transferTokens
    ) public override returns (uint) {
        _kToken;
        _src;
        _dst;
        _transferTokens;
        return allowTransfer ? noError : opaqueError;
    }

    function transferVerify(
        address _kToken,
        address _src,
        address _dst,
        uint _transferTokens
    ) external view {
        _kToken;
        _src;
        _dst;
        _transferTokens;
        require(verifyTransfer, "transferVerify rejected transfer");
    }

    function updateAndDistributeBorrowerRewardsForToken(
        address kToken,
        address borrower
    ) external pure {
        kToken;
        borrower;
        return;
    }

    function updateAndDistributeSupplierRewardsForToken(
        address kToken,
        address account
    ) external pure {
        kToken;
        account;
        return;
    }

    function _setRewardSpeeds(
        address[] memory kTokens,
        uint256[] memory supplySpeeds,
        uint256[] memory borrowSpeeds
    ) external pure {
        kTokens;
        supplySpeeds;
        borrowSpeeds;
        return;
    }

    function getBoostManager() external pure returns (address) {
        return address(0);
    }

    function getAllMarkets()
        external
        pure
        override
        returns (IKToken[] memory tokens)
    {
        return tokens;
    }

    function isMarket(address market) external pure override returns (bool) {
        return true;
    }

    /*** Special Liquidation Calculation ***/

    function liquidateCalculateSeizeTokens(
        address _kTokenBorrowed,
        address _kTokenCollateral,
        uint _repayAmount,
        uint dynamicLiquidationIncentive
    ) public view override returns (uint, uint) {
        _kTokenBorrowed;
        _kTokenCollateral;
        _repayAmount;
        return
            failCalculateSeizeTokens
                ? (opaqueError, 0)
                : (noError, calculatedSeizeTokens);
    }

    /**** Mock Settors ****/

    /*** Policy Hooks ***/

    function setMintAllowed(bool allowMint_) public {
        allowMint = allowMint_;
    }

    function setMintVerify(bool verifyMint_) public {
        verifyMint = verifyMint_;
    }

    function setRedeemAllowed(bool allowRedeem_) public {
        allowRedeem = allowRedeem_;
    }

    function setRedeemVerify(bool verifyRedeem_) public {
        verifyRedeem = verifyRedeem_;
    }

    function setBorrowAllowed(bool allowBorrow_) public {
        allowBorrow = allowBorrow_;
    }

    function setBorrowVerify(bool verifyBorrow_) public {
        verifyBorrow = verifyBorrow_;
    }

    function setRepayBorrowAllowed(bool allowRepayBorrow_) public {
        allowRepayBorrow = allowRepayBorrow_;
    }

    function setRepayBorrowVerify(bool verifyRepayBorrow_) public {
        verifyRepayBorrow = verifyRepayBorrow_;
    }

    function setLiquidateBorrowAllowed(bool allowLiquidateBorrow_) public {
        allowLiquidateBorrow = allowLiquidateBorrow_;
    }

    function setLiquidateBorrowVerify(bool verifyLiquidateBorrow_) public {
        verifyLiquidateBorrow = verifyLiquidateBorrow_;
    }

    function setSeizeAllowed(bool allowSeize_) public {
        allowSeize = allowSeize_;
    }

    function setSeizeVerify(bool verifySeize_) public {
        verifySeize = verifySeize_;
    }

    function setTransferAllowed(bool allowTransfer_) public {
        allowTransfer = allowTransfer_;
    }

    function setTransferVerify(bool verifyTransfer_) public {
        verifyTransfer = verifyTransfer_;
    }

    /*** Liquidity/Liquidation Calculations ***/

    function setCalculatedSeizeTokens(uint seizeTokens_) public {
        calculatedSeizeTokens = seizeTokens_;
    }

    function setFailCalculateSeizeTokens(bool shouldFail) public {
        failCalculateSeizeTokens = shouldFail;
    }

    function updatePrices(bytes[] calldata priceUpdateData) external override {}
}
