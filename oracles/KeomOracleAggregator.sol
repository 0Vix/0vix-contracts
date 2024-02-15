//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./PriceOracle.sol";
import "..//ktokens/KErc20.sol";
import "../ktokens/interfaces/IEIP20.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import { IApi3Server } from "./Api3/interfaces/IApi3Server.sol";
import "./chainlink/interfaces/IAggregatorV2V3.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

enum OracleProviderType {
    Chainlink,
    Pyth,
    Api3
}

struct OracleProvider {
    address oracleProviderAddress;
    function(FeedData memory) view returns (bool, uint256) getPrice;
}

struct FeedData {
    ///@dev required by Chainlink
    address feedAddress; 
    ///@dev required by Pyth and API3 
    bytes32 feedId;
    uint256 heartbeat;
    OracleProviderType oracleProviderType;
    bool isSet;
}

contract KeomOracleAggregator is Ownable, PriceOracle {
    /// @dev KToken => Feed Data
    mapping(address => FeedData) public feeds;
    /// @dev KToken => Feed Data
    mapping(address => FeedData) public fallbackFeeds;
    /// @dev Oracle Provider  => Provider Data
    mapping(OracleProviderType => OracleProvider) private oracleProviders;

    //************ * ฅ^•ﻌ•^ฅ  𝑬𝑽𝑬𝑵𝑻𝑺  ฅ^•ﻌ•^ฅ * ************//

    event FeedUpdated(address kToken, address feedAddress, bytes32 feedId, uint256 heartbeat);
    event FallbackFeedUpdated(address kToken, address feedAddress, bytes32 feedId, uint256 heartbeat);
    event PricesUpdated();

    //************ * ฅ^•ﻌ•^ฅ  CONSTRUCTOR  ฅ^•ﻌ•^ฅ * ************//

    constructor(address _pyth, address _api3Server) Ownable() {
        oracleProviders[OracleProviderType.Chainlink] = OracleProvider(address(0), _getChainlinkPrice);
        oracleProviders[OracleProviderType.Pyth] = OracleProvider(_pyth, _getPythPrice);
        oracleProviders[OracleProviderType.Api3] = OracleProvider(_api3Server, _getApi3Price);
    }

    //************ * ฅ^•ﻌ•^ฅ  GETTERS  ฅ^•ﻌ•^ฅ * ************//

    /// @notice return price of an kToken
    /// @param kToken kToken's Address
    /// @return price with 36 - tokenDecimals decimals
    function getUnderlyingPrice(IKToken kToken)
        public
        view
        override
        returns (uint256 price)
    {
        bool success;
        FeedData memory feed = feeds[address(kToken)];
        require(feed.isSet, "No primary feed set");
        (success, price) = oracleProviders[feed.oracleProviderType].getPrice(feed);

        if (!success) {
            feed = fallbackFeeds[address(kToken)];
            require(feed.isSet, "Primary heartbeat exceeded");
            (success, price) = oracleProviders[feed.oracleProviderType].getPrice(feed);
            require(success, "Secondary heartbeat exceeded");
        }

        try KErc20(address(kToken)).underlying() returns (address underlyingAddress) { 
            IEIP20 token = IEIP20(underlyingAddress);
            price *= 10**(18 - token.decimals());
        }
        catch  {
            
        }

        require(price > 0, "bad price");
    }

    //************ * ฅ^•ﻌ•^ฅ  SETTERS  ฅ^•ﻌ•^ฅ * ************//

    /**
      * @notice Updates multiple price feeds on Pyth oracle
      * @param priceUpdateData received from Pyth network and used to update the oracle
      */
    function updateUnderlyingPrices(
        bytes[] calldata priceUpdateData
    ) external override {
        IPyth pyth = IPyth(oracleProviders[OracleProviderType.Pyth].oracleProviderAddress);
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        pyth.updatePriceFeeds{ value: fee }(priceUpdateData);

        emit PricesUpdated();
    }

    function setFeed(
        address _kToken,
        address _feedAddress,
        bytes32 _feedId,
        uint256 _heartbeat,
        OracleProviderType _oracleType,
        bool isFallback
    ) external onlyOwner {
        if (_oracleType == OracleProviderType.Chainlink) {
            require(_feedId == bytes32(0) && _feedAddress != address(0), "Invalid feed");
        }
        else if (_oracleType == OracleProviderType.Pyth || _oracleType == OracleProviderType.Api3) {
            require(_feedId != bytes32(0) && _feedAddress == address(0), "invalid feed");
        }
        else {
            revert("Unsupported oracle type");
        }
        
        if (!isFallback) {
            feeds[_kToken] = FeedData(_feedAddress, _feedId, _heartbeat, _oracleType, true);
            emit FeedUpdated(_kToken, _feedAddress, _feedId, _heartbeat);
        }
        else {
            fallbackFeeds[_kToken] = FeedData(_feedAddress, _feedId, _heartbeat, _oracleType, true);
            emit FallbackFeedUpdated(_kToken, _feedAddress, _feedId, _heartbeat);
        }
    }

    //************ * ฅ^•ﻌ•^ฅ  PROVIDER-SPECIFIC GETTERS  ฅ^•ﻌ•^ฅ * ************//

    /// @notice return price of an kToken from Chainlink
    /// @param feed contains feed address required by Chainlink
    /// @return price with 18 decimals
    function _getChainlinkPrice(FeedData memory feed) internal view returns (bool, uint256)
    {
        IAggregatorV2V3 chainlinkAggregator = IAggregatorV2V3(feed.feedAddress);

        // Chainlink USD-denominated feeds store answers at 8 decimals
        uint decimalDelta = uint(18)-(chainlinkAggregator.decimals());
        (, int256 answer, , uint256 updatedAt, ) = chainlinkAggregator.latestRoundData();

        require(updatedAt > 0, "Round not complete");
        return block.timestamp <= updatedAt + feed.heartbeat ? 
            (true, uint(answer)*(10**decimalDelta)) : 
            (false, 0);
    }

    /// @notice return price of an kToken from Pyth
    /// @param feed contains feedId required by Pyth
    /// @return price with 18 decimals
    function _getPythPrice(FeedData memory feed) internal view returns (bool, uint256) {
        IPyth pyth = IPyth(oracleProviders[OracleProviderType.Pyth].oracleProviderAddress);

        PythStructs.Price memory priceData = pyth.getPriceUnsafe(feed.feedId);

        return block.timestamp < priceData.publishTime + feed.heartbeat ? 
            (true, uint256(int256(priceData.price)) * (10**(18 - _abs(priceData.expo)))) : 
            (false, 0);
    }

    /// @notice return price of an kToken from API3
    /// @param feed contains feedId required by API3
    /// @return price with 18 decimals
    function _getApi3Price(FeedData memory feed) internal view returns (bool, uint256) {
         
        IApi3Server api3Server = IApi3Server(oracleProviders[OracleProviderType.Api3].oracleProviderAddress);
        (int224 value, uint lastUpdatedAt) = api3Server.readDataFeedWithId(feed.feedId);

        return block.timestamp < lastUpdatedAt + feed.heartbeat ? 
            (true, uint256(int256(value))) : 
            (false, 0);
    }

    //************ * ฅ^•ﻌ•^ฅ  UTILS  ฅ^•ﻌ•^ฅ * ************//

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    receive() external payable {}
}
