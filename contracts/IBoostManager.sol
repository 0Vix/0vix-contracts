//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBoostManager {
    function initialize(IERC20 ve) external;

    function updateBoostBasisBytes32(bytes32[] calldata markets, address user)
        external;

    function updateBoostBasis(address[] calldata markets, address user) external; //calldata because of compiler version issues

    function updateBoostSupplyBalances(
        address market,
        address user,
        uint256 oldBalance,
        uint256 newBalance
    ) external;

    function updateBoostBorrowBalances(
        address market,
        address user,
        uint256 oldBalance,
        uint256 newBalance
    ) external;

    function boostedSupplyBalanceOf(address market, address user)
        external
        view
        returns (uint256);

    function boostedBorrowBalanceOf(address market, address user)
        external
        view
        returns (uint256);

    function boostedTotalSupply(address market) external view returns (uint256);

    function boostedTotalBorrows(address market)
        external
        view
        returns (uint256);

    function setAuthorized(address addr, bool flag) external;

    function setVeOVIX(IERC20 ve) external;

    function isAuthorized(address addr) external view returns (bool);
}
