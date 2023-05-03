// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

error NotImplemented();

contract PythMock is IPyth {
    mapping(bytes32 => PythStructs.Price) prices;

    constructor(bytes32[] memory tokenIdArr, int64[] memory priceArr) {
        for(uint i=0; i < tokenIdArr.length; i++) {
            prices[tokenIdArr[i]] = PythStructs.Price(priceArr[i], 0, -8, 0);
        }
    }

    function getValidTimePeriod() external view returns (uint validTimePeriod) {
        revert NotImplemented();
    }

    function getPrice(
        bytes32 id
    ) external view returns (PythStructs.Price memory price) {
        revert NotImplemented();
    }

    function getEmaPrice(
        bytes32 id
    ) external view returns (PythStructs.Price memory price) {
        revert NotImplemented();
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory price) {
        price = prices[id];
        price.publishTime = block.timestamp;
    }

    function getPriceNoOlderThan(
        bytes32 id,
        uint age
    ) external view returns (PythStructs.Price memory price) {
        revert NotImplemented();
    }

    function getEmaPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory price) {
        revert NotImplemented();
    }

    function getEmaPriceNoOlderThan(
        bytes32 id,
        uint age
    ) external view returns (PythStructs.Price memory price) {
        revert NotImplemented();
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        revert NotImplemented();
    }

    function updatePriceFeedsIfNecessary(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64[] calldata publishTimes
    ) external payable {
        revert NotImplemented();
    }

    function getUpdateFee(
        bytes[] calldata updateData
    ) external view returns (uint feeAmount) {
        revert NotImplemented();
    }
    function parsePriceFeedUpdates(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory priceFeeds) {
        revert NotImplemented();
    }
}
