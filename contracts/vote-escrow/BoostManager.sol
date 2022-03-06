//SPDX-License-Identifier: MIT
pragma solidity =0.8.4;

import "../openzeppelin@4.5.0/Ownable.sol";
import "../openzeppelin@4.5.0/token/ERC20/IERC20.sol";
import "../interfaces/IoToken.sol";
import "./IComptroller.sol";


contract BoostManager is Ownable {
    bool public init = true; //todo set to true when using proxy
    uint256 private constant MULTIPLIER = 10**18;

    IERC20 public veOVIX;
    IComptroller public comptroller;

    mapping(address => bool) public authorized;
    // market => user => supply boostBasis
    mapping(address => mapping(address => uint256)) public supplyBoosterBasis;
    // market => user => borrow boostBasis
    mapping(address => mapping(address => uint256)) public borrowBoosterBasis;
    // user => veBalance
    mapping(address => uint256) public veBalances;

    mapping(address => uint256) private deltaTotalSupply;
    mapping(address => uint256) private deltaTotalBorrows;

    constructor() {}

    function initialize(IERC20 ve, IComptroller _comptroller, address _owner) external {
        require(!init, "contract already initialized");
        init = true;
        veOVIX = ve;
        comptroller = _comptroller;
        _transferOwnership(_owner);
    }

    modifier onlyAuthorized() {
        require(
            authorized[msg.sender] || comptroller.isMarket(msg.sender),
            "sender is not authorized"
        );
        _;
    }

    /**
     * @notice Updates the boost basis of the user with the latest veBalance
     * @param user Address of the user which booster needs to be updated 
     * @return The boolean value indicating whether the user still has the booster greater than 1.0
     */
    function updateBoostBasis(address user)
        external
        onlyAuthorized
        returns (bool)
    {
        address[] memory markets = comptroller.getAllMarkets();

        veBalances[user] = veOVIX.balanceOf(user);
        for (uint256 i = 0; i < markets.length; i++) {
            _updateBoostBasisPerMarket(markets[i], user);
        }

        return veBalances[user] == 0 ? false : true;
    }

    function _updateBoostBasisPerMarket(address market, address user) internal {
        uint256 userSupply = IoToken(market).balanceOf(user);
        uint256 userBorrows = IoToken(market).borrowBalanceStored(user);
        if (userSupply > 0) {
            uint256 oldSupplyBoostBasis = supplyBoosterBasis[market][user];
            comptroller.updateAndDistributeSupplierRewardsForToken(
                market,
                user
            );
            _updateSupplyBoostBasis(market, user);
            _updateBoostBalance(
                market,
                user,
                userSupply,
                userSupply,
                oldSupplyBoostBasis,
                supplyBoosterBasis[market][user],
                0
            );
        }
        if (userBorrows > 0) {
            uint256 oldBorrowBoostBasis = borrowBoosterBasis[market][user];
            comptroller.updateAndDistributeBorrowerRewardsForToken(
                market,
                user
            );
            _updateBorrowBoostBasis(market, user);
            _updateBoostBalance(
                market,
                user,
                userBorrows,
                userBorrows,
                oldBorrowBoostBasis,
                borrowBoosterBasis[market][user],
                1
            );
        }
    }

    function _updateSupplyBoostBasis(address market, address user) internal {
        supplyBoosterBasis[market][user] = calcBoostBasis(market, 0);
    }

    function _updateBorrowBoostBasis(address market, address user) internal {
        borrowBoosterBasis[market][user] = calcBoostBasis(market, 1);
    }

    // call from oToken
    function updateBoostSupplyBalances(
        address market,
        address user,
        uint256 oldBalance,
        uint256 newBalance
    ) external onlyAuthorized {
        _updateBoostBalance(
            market,
            user,
            oldBalance,
            newBalance,
            supplyBoosterBasis[market][user],
            supplyBoosterBasis[market][user],
            0
        );
    }

    function updateBoostBorrowBalances(
        address market,
        address user,
        uint256 oldBalance,
        uint256 newBalance
    ) external onlyAuthorized {
        _updateBoostBalance(
            market,
            user,
            oldBalance,
            newBalance,
            borrowBoosterBasis[market][user],
            borrowBoosterBasis[market][user],
            1
        );
    }

    function _updateBoostBalance(
        address market,
        address user,
        uint256 oldBalance,
        uint256 newBalance,
        uint256 oldBoostBasis,
        uint256 newBoostBasis,
        uint256 marketType
    ) internal {
        // todo: add min/max
        uint256 deltaOldBalance = calcBoostedBalance(
            user,
            oldBoostBasis,
            oldBalance
        ) - oldBalance;
        uint256 deltaNewBalance = calcBoostedBalance(
            user,
            newBoostBasis,
            newBalance
        ) - newBalance;
        if (marketType == 0) {
            deltaTotalSupply[market] =
                deltaTotalSupply[market] +
                deltaNewBalance -
                deltaOldBalance;
        } else {
            deltaTotalBorrows[market] =
                deltaTotalBorrows[market] +
                deltaNewBalance -
                deltaOldBalance;
        }
    }

    // marketType: 0 = supply, 1 = borrow
    // boost basis = totalVeSupply/marketLiquidity
    function calcBoostBasis(address market, uint256 marketType)
        internal
        view
        returns (uint256)
    {
        require(marketType <= 1, "wrong market type");

        if (marketType == 0) {
            if (IoToken(market).totalSupply() == 0) return 0; // nothing to calculate if market is empty
            return ((veOVIX.totalSupply() * MULTIPLIER) / // todo: check correctness of zero balance handling
                IoToken(market).totalSupply()); // todo
        } else {
            if (IoToken(market).totalBorrows() == 0) return 0;
            return ((veOVIX.totalSupply() * MULTIPLIER) / // todo
                IoToken(market).totalBorrows()); // todo
        }
    }

    // booster: if(veBalanceOfUser >= boostBasis * userBalance) = 2.5
    // booster: else: 1.5*veBalanceOfUser/(boostBasis * userBalance) + 1 = [1 <= booster < 2.5]
    // bosted balance = booster * userBalance
    function calcBoostedBalance(
        address user,
        uint256 boosterBasis,
        uint256 balance
    ) internal view returns (uint256) {
        if (boosterBasis == 0) return balance;

        uint256 minVe = (boosterBasis * balance) / MULTIPLIER;
        uint256 booster;

        if (veBalances[user] >= minVe) {
            booster = 25 * MULTIPLIER; // = 2,5
        } else {
            booster =
                ((15 * MULTIPLIER * veBalances[user]) / minVe) +
                10 *
                MULTIPLIER; // 1.5 * veBalance / minVe + 1;
        }

        return ((balance * booster) / (10 * MULTIPLIER));
    }

    function boostedSupplyBalanceOf(address market, address user)
        public
        view
        returns (uint256)
    {
        return (
            calcBoostedBalance(
                user,
                supplyBoosterBasis[market][user],
                IoToken(market).balanceOf(user)
            )
        );
    }

    function boostedBorrowBalanceOf(address market, address user)
        public
        view
        returns (uint256)
    {
        return (
            calcBoostedBalance(
                user,
                borrowBoosterBasis[market][user],
                IoToken(market).borrowBalanceStored(user)
            )
        );
    }

    function boostedTotalSupply(address market)
        external
        view
        returns (uint256)
    {
        return (IoToken(market).totalSupply() + deltaTotalSupply[market]);
    }

    function boostedTotalBorrows(address market)
        external
        view
        returns (uint256)
    {
        return (IoToken(market).totalBorrows() + deltaTotalBorrows[market]);
    }

    function setAuthorized(address addr, bool flag) external onlyOwner {
        authorized[addr] = flag;
    }

    function isAuthorized(address addr) external view returns (bool) {
        return authorized[addr];
    }

    function setVeOVIX(IERC20 ve) external onlyOwner {
        veOVIX = ve;
    }
}
