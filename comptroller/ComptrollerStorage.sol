//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../ktokens/interfaces/IKToken.sol";
import "../oracles/PriceOracle.sol";

import "../interfaces/IComptroller.sol";
import "./UnitrollerAdminStorage.sol";
import "../rewards/interfaces/IRewardManager.sol";

interface IBoostManager {

} 

abstract contract ComptrollerV1Storage is IComptroller, UnitrollerAdminStorage  {
    /**
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public override oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => IKToken[]) public accountAssets;

    /// @notice Per-market mapping of "accounts in this asset"
    mapping(address => mapping(address => bool)) public accountMembership;

}

abstract contract ComptrollerV2Storage is ComptrollerV1Storage {
    struct Market {
        /// @notice Whether or not this market is listed
        bool isListed;
        // markets marked with autoCollaterize are automatically set as collateral for the user at the first mint
        bool autoCollaterize;
        /**
         * @notice Multiplier representing the most one can borrow against their collateral in this market.
         *  For instance, 0.9 to allow borrowing 90% of collateral value.
         *  Must be between 0 and 1, and stored as a mantissa.
         */
        uint collateralFactorMantissa;
    }

    /**
     * @notice Official mapping of kTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;


    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     *  Actions which allow users to remove their own assets cannot be paused.
     *  Liquidation / seizing / transfer can only be paused globally, not by market.
     */
    address public pauseGuardian;
    bool public _mintGuardianPaused;
    bool public _borrowGuardianPaused;
    bool public transferGuardianPaused;
    bool public seizeGuardianPaused;
    struct PauseData {
        bool mint;
        bool borrow;
        bool redeem;
        bool repay;
    }

    mapping(address => PauseData) public guardianPaused;
}

abstract contract ComptrollerV3Storage is ComptrollerV2Storage {
    struct MarketState {
        /// @notice The market's last updated tokenBorrowIndex or tokenSupplyIndex
        uint224 index;

        /// @notice The timestamp the index was last updated at
        uint32 timestamp;
    }

    /// @notice A list of all markets
    IKToken[] public allMarkets;

    /// @notice The rate at which the flywheel distributes TKN, per second
    uint public compRate;

    /// @notice The portion of compRate that each market currently receives
    mapping(address => uint) public rewardSpeeds;

    /// @notice The Protocol market supply state for each market
    mapping(address => MarketState) public supplyState;

    /// @notice The Protocol market borrow state for each market
    mapping(address => MarketState) public borrowState;

    /// @notice The Protocol borrow index for each market for each supplier as of the last time they accrued TKN
    mapping(address => mapping(address => uint)) public rewardSupplierIndex;

    /// @notice The Protocol borrow index for each market for each borrower as of the last time they accrued TKN
    mapping(address => mapping(address => uint)) public rewardBorrowerIndex;

    /// @notice The TKN accrued but not yet transferred to each user
    mapping(address => uint) public rewardAccrued;

}

abstract contract ComptrollerV4Storage is ComptrollerV3Storage {
    // @notice The xapGuardian can set caps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public capGuardian;

    // @notice Borrow caps enforced by borrowAllowed for each kToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;
}

abstract contract ComptrollerV5Storage is ComptrollerV4Storage {
    /// @notice The portion of TKN that each contributor receives per second
    mapping(address => uint) public rewardContributorSpeeds;

    /// @notice Last timestamp at which a contributor's TKN rewards have been allocated
    mapping(address => uint) public lastContributorTimestamp;
}

abstract contract ComptrollerV6Storage is ComptrollerV5Storage {
    /// @notice The rate at which TKN is distributed to the corresponding borrow market (per second)
    mapping(address => uint) public rewardBorrowSpeeds;

    /// @notice The rate at which TKN is distributed to the corresponding supply market (per second)
    mapping(address => uint) public rewardSupplySpeeds;
}

abstract contract ComptrollerV7Storage is ComptrollerV6Storage {
    /// @notice Accounting storage mapping account addresses to how much TKN they owe the protocol.
    mapping(address => uint) public rewardReceivable;

    IBoostManager public boostManager;
}

abstract contract ComptrollerV8Storage is ComptrollerV7Storage {
    /// @notice 
    IRewardManager public rewardManager;
}

abstract contract ComptrollerV9Storage is ComptrollerV8Storage {
    /// @notice 
    mapping(address => uint256) public supplyCaps;
}