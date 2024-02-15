//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../PriceOracle.sol";
import "../../ktokens/KErc20.sol";
import "../../ktokens/interfaces/IEIP20.sol";

interface IExOraclePriceData
{
    function latestRoundData(
        string calldata priceType, 
        address dataSource
    ) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function get(string calldata priceType, address source) external view returns (uint256 price, uint256 timestamp);

    function getOffchain(
        string calldata priceType, 
        address source
    ) external view returns (uint256 price, uint256 timestamp);

    function getCumulativePrice(
        string calldata priceType, 
        address source
    ) external view returns (uint256 cumulativePrice,uint32 timestamp);

    function lastResponseTime(address source) external view returns (uint256);
}

error NotImplemented();

contract KeomX1Oracle is PriceOracle {
    address public admin;
    address public kNative;
    address public immutable x1Oracle;
    address public immutable dataSource;

    mapping(string => uint256) public heartbeats;
    mapping(address => string) internal feeds;

    event NewAdmin(address oldAdmin, address newAdmin);
    event FeedSet(string feed, address asset);
    event HeartbeatSet(string feed, uint256 heartbeat);

    constructor(address _cNative, address _x1Oracle, address _dataSource) {
        admin = msg.sender;
        x1Oracle = _x1Oracle;
        dataSource = _dataSource;
        _setKNative(_cNative);
    }

    function getUnderlyingPrice(IKToken kToken) public view override returns (uint price)
    {
        uint decimals = 18;
        if (address(kToken) != kNative) {
            IEIP20 token = IEIP20(KErc20(address(kToken)).underlying());
            decimals = uint(token.decimals());
        }
        
        string memory feed = getFeed(address(kToken));
        if (bytes(feed).length > 0) {
            price = getX1Price(feed);
        }

        require(price > 0, "bad price");

        uint decimalDelta = uint(18) - decimals;
        return price*(10**decimalDelta);
    }

    function getX1Price(string memory feed) internal view returns (uint)
    {
        uint decimalDelta = 12;

        (uint256 answer, uint256 updatedAt) = IExOraclePriceData(x1Oracle).get(feed, dataSource);
        require(updatedAt > 0, "Round not complete");
        require(
            block.timestamp <= updatedAt+((heartbeats[feed] * 15) / 10),
            "Update time (heartbeat) exceeded"
        );

        return uint(answer)*(10**decimalDelta);
    }

    function setFeed(address kToken, string calldata feed, uint256 heartbeat) external onlyAdmin {
        require(bytes(feed).length > 0,"invalid feed address");

        heartbeats[feed] = heartbeat;
        feeds[kToken] = feed;

        emit FeedSet(feed, kToken);
        emit HeartbeatSet(feed, heartbeat);
    }

    function setHeartbeat(address kToken, uint256 heartbeat) external onlyAdmin
    {
        string memory feed = feeds[kToken];
        heartbeats[feed] = heartbeat;

        emit HeartbeatSet(feed, heartbeat);
    }

    function getFeed(address kToken) public view returns (string memory) {
        return feeds[kToken];
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        emit NewAdmin(admin, newAdmin);
        admin = newAdmin;        
    }

    function setKNative(address _cNative) external onlyAdmin {
        _setKNative(_cNative);
    }

    function _setKNative(address _cNative) internal {
        kNative = _cNative;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin may call");
        _;
    }

    function updateUnderlyingPrices(bytes[] calldata) external pure override {
        revert NotImplemented();
    }
}
