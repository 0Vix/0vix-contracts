pragma solidity 0.5.17;

import "./OToken.sol";
import "./PriceOracle.sol";

contract UnitrollerAdminStorage {
    /**
    * @notice Administrator for this contract
    */
    address public admin;

    /**
    * @notice Pending administrator for this contract
    */
    address public pendingAdmin;

    /**
    * @notice Active brains of Unitroller
    */
    address public comptrollerImplementation;

    /**
    * @notice Pending brains of Unitroller
    */
    address public pendingComptrollerImplementation;
}

contract ComptrollerVXStorage is UnitrollerAdminStorage {

    /**
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public oracle;

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
    mapping(address => OToken[]) public accountAssets;

    struct Market {
        /// @notice Whether or not this market is listed
        bool isListed;

        /// @notice Whether or not this market receives 0VIX
        bool isOed;

        /**
         * @notice Multiplier representing the most one can borrow against their collateral in this market.
         *  For instance, 0.9 to allow borrowing 90% of collateral value.
         *  Must be between 0 and 1, and stored as a mantissa.
         */
        uint collateralFactorMantissa;

        /// @notice Per-market mapping of "accounts in this asset"
        mapping(address => bool) accountMembership;
    }

    /**
     * @notice Official mapping of oTokens -> Market metadata
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
    }

    mapping(address => PauseData) public guardianPaused;

    /// @notice A list of all markets
    OToken[] public allMarkets;

    // @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    // @notice Borrow caps enforced by borrowAllowed for each oToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;

    struct RewardMarketState {
        /// @notice The market's last updated rewardBorrowIndex or rewardSupplyIndex
        uint224 index;

        /// @notice The block timestamp the index was last updated at
        uint32 timestamp;
    }

    /// @notice The rate at which the flywheel distributes reward, per timestamp
    mapping(uint8 => uint) rewardRate;

    /// @notice The portion of reward rate that each market currently receives
    mapping(uint8 => mapping(address => uint)) public rewardSpeeds;

    /// @notice The O/MATIC market supply state for each market
    mapping(uint8 => mapping(address => RewardMarketState)) public rewardSupplyState;

    /// @notice The O/MATIC market borrow state for each market
    mapping(uint8 =>mapping(address => RewardMarketState)) public rewardBorrowState;

    /// @notice The O/MATIC borrow index for each market for each supplier as of the last time they accrued reward
    mapping(uint8 => mapping(address => mapping(address => uint))) public rewardSupplierIndex;

    /// @notice The O/MATIC borrow index for each market for each borrower as of the last time they accrued reward
    mapping(uint8 => mapping(address => mapping(address => uint))) public rewardBorrowerIndex;

    /// @notice The O/MATIC accrued but not yet transferred to each user
    mapping(uint8 => mapping(address => uint)) public rewardAccrued;

    /// @notice O token contract address
    address public oAddress;
}
