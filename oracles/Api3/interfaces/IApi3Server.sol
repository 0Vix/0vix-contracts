//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IApi3Server {
    function accessControlRegistry() external view returns (address);

    function adminRole() external view returns (bytes32);

    function adminRoleDescription() external view returns (string memory);

    function containsBytecode(address account) external view returns (bool);

    function dapiNameHashToDataFeedId(bytes32) external view returns (bytes32);

    function dapiNameSetterRole() external view returns (bytes32);

    function dapiNameToDataFeedId(
        bytes32 dapiName
    ) external view returns (bytes32);

    function dataFeeds(
        bytes32 dataFeedId
    ) external view returns (int224 value, uint32 timestamp);

    function getBalance(address account) external view returns (uint256);

    function getBlockBasefee() external view returns (uint256);

    function getBlockNumber() external view returns (uint256);

    function getBlockTimestamp() external view returns (uint256);

    function getChainId() external view returns (uint256);

    function manager() external view returns (address);

    function multicall(
        bytes[] memory data
    ) external returns (bytes[] memory returndata);

    function oevProxyToBalance(address) external view returns (uint256);

    function oevProxyToIdToDataFeed(
        address proxy,
        bytes32 dataFeedId
    ) external view returns (int224 value, uint32 timestamp);

    function readDataFeedWithDapiNameHash(
        bytes32 dapiNameHash
    ) external view returns (int224 value, uint32 timestamp);

    function readDataFeedWithDapiNameHashAsOevProxy(
        bytes32 dapiNameHash
    ) external view returns (int224 value, uint32 timestamp);

    function readDataFeedWithId(
        bytes32 dataFeedId
    ) external view returns (int224 value, uint32 timestamp);

    function readDataFeedWithIdAsOevProxy(
        bytes32 dataFeedId
    ) external view returns (int224 value, uint32 timestamp);

    function setDapiName(bytes32 dapiName, bytes32 dataFeedId) external;

    function tryMulticall(
        bytes[] memory data
    ) external returns (bool[] memory successes, bytes[] memory returndata);

    function updateBeaconSetWithBeacons(
        bytes32[] memory beaconIds
    ) external returns (bytes32 beaconSetId);

    function updateBeaconWithSignedData(
        address airnode,
        bytes32 templateId,
        uint256 timestamp,
        bytes memory data,
        bytes memory signature
    ) external returns (bytes32 beaconId);

    function updateOevProxyDataFeedWithSignedData(
        address oevProxy,
        bytes32 dataFeedId,
        bytes32 updateId,
        uint256 timestamp,
        bytes memory data,
        bytes[] memory packedOevUpdateSignatures
    ) external;

    function withdraw(address oevProxy) external;
}
