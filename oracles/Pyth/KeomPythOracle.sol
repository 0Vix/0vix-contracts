//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../chainlink/PriceOracle.sol";
import "../../ktokens/KErc20.sol";
import "../../ktokens/interfaces/IEIP20.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract KeomPythOracle is Ownable, PriceOracle {
    ///@dev valid Period for our oracle updates
    uint256 public validPeriod;
    ///@dev kToken from chain's native asset
    address public kNative;
    ///@dev pyth oracle
    IPyth public pyth;

    struct PriceData {
        uint256 price;
        uint256 updatedAt;
    }

    /// @dev Pyth's Token ID => heartbeat
    mapping(bytes32 => uint256) public heartbeats;
    /// @dev KToken => Pyth's Token ID
    mapping(address => bytes32) public getFeed;
    /// @dev KToken => Our Token Data
    mapping(address => PriceData) public prices;

    //************ * ฅ^•ﻌ•^ฅ  𝑬𝑽𝑬𝑵𝑻𝑺  ฅ^•ﻌ•^ฅ * ************//

    event NewAdmin(address oldAdmin, address newAdmin);
    event TokenIdSet(bytes32 tokenId, address kToken);
    event PricePosted(
        address asset,
        uint256 previousPrice,
        uint256 newPrice,
        uint256 updatedAt
    );
    event HeartbeatSet(bytes32 tokenId, uint256 heartbeat);
    event ValidPeriodSet(uint256 validPeriod);
    event ONativeSet(address kNative);

    //************ * ฅ^•ﻌ•^ฅ  CONSTRUCTOR  ฅ^•ﻌ•^ฅ * ************//

    constructor(address _cNative, address _pyth) Ownable() {
        validPeriod = 300; // 5 minutes
        kNative = _cNative;
        pyth = IPyth(_pyth);
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
        if (address(kToken) == kNative) {
            price = _getPythPrice(getFeed[address(kToken)]);
        } else {
            price = _getPrice(address(kToken));
        }
        require(price > 0, "bad price");
    }

    /// @notice return price of an kToken
    /// @param kToken kToken's Address
    /// @return price with 36 - tokenDecimals decimals
    function _getPrice(address kToken) internal view returns (uint256 price) {
        IEIP20 token = IEIP20(KErc20(address(kToken)).underlying());

        bytes32 tokenId = getFeed[kToken];
        if (tokenId != bytes32(0)) {
            price = _getPythPrice(tokenId);
        } else if (
            prices[address(kToken)].updatedAt >= block.timestamp - validPeriod
        ) {
            price = prices[address(kToken)].price;
        }
        require(price > 0, "bad price");
        return price * 10**(18 - token.decimals());
    }

    /// @notice return price of an kToken
    /// @param _tokenId Pyth's tokenId
    /// @return price with 18 decimals
    function _getPythPrice(bytes32 _tokenId) internal view returns (uint256) {
        PythStructs.Price memory priceData = pyth.getPriceUnsafe(_tokenId);
        require(
            block.timestamp < priceData.publishTime + (heartbeats[_tokenId]),
            "Update time (heartbeat) exceeded"
        );
        return
            uint256(int256(priceData.price)) *
            (10**(18 - _abs(priceData.expo)));
    }

    //************ * ฅ^•ﻌ•^ฅ  SETTERS  ฅ^•ﻌ•^ฅ * ************//

    function setUnderlyingPrice(
        address kToken,
        uint256 underlyingPriceMantissa,
        uint256 updatedAt
    ) external onlyOwner {
        require(underlyingPriceMantissa > 0, "bad price");
        if (block.timestamp > updatedAt) {
            // reject stale price
            // validPeriod can be set to 5 mins
            require(block.timestamp - updatedAt < validPeriod, "bad updatedAt");
        } else {
            // reject future timestamp (< 3s is allowed)
            require(updatedAt - block.timestamp < 3, "bad updatedAt");
            updatedAt = block.timestamp;
        }
        prices[kToken] = PriceData(underlyingPriceMantissa, updatedAt);

        emit PricePosted(
            kToken,
            prices[kToken].price,
            underlyingPriceMantissa,
            updatedAt
        );
    }

    function setTokenId(
        address _kToken,
        bytes32 _tokenId,
        uint256 _heartbeat
    ) external onlyOwner {
        require(_tokenId != bytes32(0), "invalid tokenId");
        heartbeats[_tokenId] = _heartbeat;
        getFeed[_kToken] = _tokenId;
        emit TokenIdSet(_tokenId, _kToken);
        emit HeartbeatSet(_tokenId, _heartbeat);
    }

    function setHeartbeat(address kToken, uint256 heartbeat)
        external
        onlyOwner
    {
        bytes32 tokenId = getFeed[kToken];
        heartbeats[tokenId] = heartbeat;
        emit HeartbeatSet(tokenId, heartbeat);
    }

    function setValidPeriod(uint256 period) external onlyOwner {
        validPeriod = period;
        emit ValidPeriodSet(period);
    }

    function setONative(address _kNative) external onlyOwner {
        kNative = _kNative;
        emit ONativeSet(_kNative);
    }

    //************ * ฅ^•ﻌ•^ฅ  UTILS  ฅ^•ﻌ•^ฅ * ************//

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }
}
