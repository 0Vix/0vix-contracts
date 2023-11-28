//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { PriceOracle } from "../chainlink/PriceOracle.sol";
import { KErc20 } from "../../ktokens/KErc20.sol";
import { IKToken } from "../../ktokens/interfaces/IKToken.sol";
import { IEIP20 } from "../../ktokens/interfaces/IEIP20.sol";
import { IApi3Server } from "./interfaces/IApi3Server.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract KeomApi3Oracle is Ownable, PriceOracle {
    ///@dev kToken from chain's native asset
    address public kNative;
    address public api3;
    IApi3Server public api3Server;

    mapping(bytes32 => uint256) public heartbeats;
    mapping(address => bytes32) public feeds;

    event TokenIdSet(bytes32 tokenId, address kToken);
    event HeartbeatSet(bytes32 tokenId, uint256 heartbeat);
    event KNativeSet(address kNative);

    constructor(address _kNative, IApi3Server _api3Server) Ownable() {
        kNative = _kNative;
        api3Server = _api3Server;
    }

    // @notice return price of an kToken underlying
    // @param kToken kToken's Address
    // @return price with 36 - tokenDecimals decimals
    function getUnderlyingPrice(
        IKToken kToken
    ) public view override returns (uint256 price) {
        uint underlyingDecimals = 18; // decimals are always 18 for gas token
        if (address(kToken) != kNative) {
            IEIP20 underlying = IEIP20(KErc20(address(kToken)).underlying());
            underlyingDecimals = underlying.decimals();
        }
        bytes32 feedId = feeds[address(kToken)];
        price = _getApi3Price(feedId) * 10 ** (18 - underlyingDecimals); //36 - underlying decimals
        require(price > 0, "bad price");
    }

    function _getApi3Price(bytes32 _tokenId) internal view returns (uint256) {
        (int224 value, uint lastUpdatedAt) = api3Server.readDataFeedWithId(
            _tokenId
        );
        require(
            block.timestamp < lastUpdatedAt + (heartbeats[_tokenId]),
            "Update time (heartbeat) exceeded"
        );
        return uint256(int256(value));
    }

    function setTokenId(
        address _kToken,
        bytes32 _tokenId,
        uint256 _heartbeat
    ) external onlyOwner {
        require(_tokenId != bytes32(0), "invalid tokenId");
        heartbeats[_tokenId] = _heartbeat;
        feeds[_kToken] = _tokenId;
        emit TokenIdSet(_tokenId, _kToken);
        emit HeartbeatSet(_tokenId, _heartbeat);
    }

    function setHeartbeat(
        address kToken,
        uint256 heartbeat
    ) external onlyOwner {
        bytes32 tokenId = feeds[kToken];
        heartbeats[tokenId] = heartbeat;
        emit HeartbeatSet(tokenId, heartbeat);
    }

    function setKNative(address _kNative) external onlyOwner {
        kNative = _kNative;
        emit KNativeSet(_kNative);
    }
}
