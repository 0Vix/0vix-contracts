pragma solidity ^0.8.4;

interface IComptroller {
    function _setRewardSpeeds(
        address[] memory oToken,
        uint256[] memory supplyRewardSpeeds,
        uint256[] memory borrowRewardSpeeds
    ) external;

    function isMarket(address market) external view returns (bool); // todo: needs to be added to comptroller

    function updateAndDistributeSupplierRewardsForToken(
        address oToken,
        address account
    ) external;

    function updateAndDistributeBorrowerRewardsForToken(
        address oToken,
        address borrower
    ) external;

    function getAllMarkets() external view returns (address[] memory);
}
