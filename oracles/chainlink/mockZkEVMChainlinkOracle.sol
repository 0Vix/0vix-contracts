// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./interfaces/IAggregatorV2V3.sol";
import "../../otokens/OErc20.sol";
import "../../otokens/interfaces/IEIP20.sol";
import "./PriceOracle.sol";

/**
 * @title MockV3Aggregator **modified**
 * @notice Based on the 0vixOralce and FluxAggregator contract,
 * @notice Use this contract when you need to test
 * other contract's ability to read data from an
 * aggregator contract, but how the aggregator got
 * its answer is unimportant
 */

contract MockV3Aggregator is IAggregatorV2V3, PriceOracle {
    error isoWETH();
    error isZeroAddress();

    event PricePosted(
        address asset,
        uint256 previousPrice,
        uint256 newPrice,
        uint256 updatedAt
    );
    event NewAdmin(address oldAdmin, address newAdmin);
    event NewOWETH(address oldOWETH, address newOWETH);

    uint256 public constant override version = 0;
    uint8 public override decimals;
    int256 public override latestAnswer;
    uint256 public override latestTimestamp;
    uint256 public override latestRound;
    uint256 public validPeriod;
    address public oWETH;
    address public admin;

    struct PriceData {
        uint256 price;
        uint256 updatedAt;
    }

    mapping(uint256 => int256) public override getAnswer;
    mapping(uint256 => uint256) public override getTimestamp;
    mapping(uint256 => uint256) private getStartedAt;
    mapping(address => PriceData) internal prices;
    mapping(address => address) internal underlyingTokenAddress;

    modifier onlyAdmin() {
        require(msg.sender == admin, "mock: only admin may call");
        _;
    }

    constructor(uint8 _decimals, uint256 _validPeriod) {
        admin = msg.sender;
        decimals = _decimals;
        validPeriod = _validPeriod;
    }

    // @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ public @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ //
    function getUnderlyingPrice(IOToken oToken)
        public
        view
        override
        returns (uint256)
    {
        if (address(oToken) == oWETH) {
            return getNativePrice(oToken);
        }
        return getPrice(oToken);
    }

    function getUnderlyingTokenAddress(address oToken)
        public
        view
        returns (address)
    {
        address awnser = underlyingTokenAddress[oToken];
        if (awnser == address(0)) revert isZeroAddress();
        return awnser;
    }

    // @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ external @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ //
    function setUnderlyingPrice(
        address oToken,
        uint256 underlyingPriceMantissa,
        uint256 updatedAt
    ) external onlyAdmin {
        require(underlyingPriceMantissa > 0, "mock: 0, bad price");
        if (block.timestamp > updatedAt) {
            // reject stale price
            // validPeriod can be set to 5 mins
            require(
                block.timestamp - updatedAt < validPeriod,
                "mock: bad updatedAt"
            );
        } else {
            // reject future timestamp (< 3s is allowed)
            require(updatedAt - block.timestamp < 3, "mock: bad updatedAt 2");
            updatedAt = block.timestamp;
        }
        if (oToken == oWETH) {
            // underlyingPriceMantissa 8 decimals
            updateAnswer(int256(underlyingPriceMantissa));
            emit PricePosted(
                oWETH,
                prices[oWETH].price,
                underlyingPriceMantissa,
                updatedAt
            );
            prices[oWETH] = PriceData(underlyingPriceMantissa, updatedAt);
        } else {
            address underlyingToken = getUnderlyingTokenAddress(oToken);
            emit PricePosted(
                underlyingToken,
                prices[underlyingToken].price,
                underlyingPriceMantissa,
                updatedAt
            );
            prices[underlyingToken] = PriceData(
                underlyingPriceMantissa,
                updatedAt
            );
        }
    }

    function setUnderlyingTokenAddress(IOToken oToken) external onlyAdmin {
        if (address(oToken) == oWETH) revert isoWETH();

        IEIP20 token = IEIP20(OErc20(address(oToken)).underlying());

        if (address(token) == address(0)) revert isZeroAddress();

        underlyingTokenAddress[address(oToken)] = address(token);
    }

    function updateRoundData(
        uint80 _roundId,
        int256 _answer,
        uint256 _timestamp,
        uint256 _startedAt
    ) external onlyAdmin {
        latestRound = _roundId;
        latestAnswer = _answer;
        latestTimestamp = _timestamp;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = _timestamp;
        getStartedAt[latestRound] = _startedAt;
    }

    function setOWETH(address _oWETH) external onlyAdmin {
        emit NewOWETH(oWETH, _oWETH);
        _setOWETH(_oWETH);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        emit NewAdmin(admin, newAdmin);
        _setAdmin(newAdmin);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            _roundId,
            getAnswer[_roundId],
            getStartedAt[_roundId],
            getTimestamp[_roundId],
            _roundId
        );
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            uint80(latestRound),
            getAnswer[latestRound],
            getStartedAt[latestRound],
            getTimestamp[latestRound],
            uint80(latestRound)
        );
    }

    function description() external pure override returns (string memory) {
        return "modified v0.8/tests/MockV3Aggregator.sol";
    }

    // @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ internal @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ //
    function getPrice(IOToken oToken) internal view returns (uint256 price) {
        IEIP20 token = IEIP20(OErc20(address(oToken)).underlying());
        // removing this for tests
        // if (prices[address(token)].updatedAt >= block.timestamp - validPeriod) {
        price = prices[address(token)].price;
        // }
        require(price > 0, "mock: bad price");

        uint256 decimalDelta = uint256(18) - (uint256(token.decimals()));
        // ensure that we don't multiply the result by 0
        if (decimalDelta > 0) {
            return price * (10**decimalDelta);
        } else {
            return price;
        }
    }

    function getNativePrice(IOToken oToken)
        internal
        view
        returns (uint256 price)
    {
        require(address(oToken) == oWETH, "mock: not native");

        uint256 decimalDelta = uint256(18) -
            (uint256(OErc20(address(oToken)).decimals()));
        // removing this for tests
        // if (
        //     prices[address(oToken)].updatedAt >= block.timestamp - validPeriod
        // ) {
        price = prices[address(oToken)].price;
        // }

        if (decimalDelta > 0) {
            return price * (10**decimalDelta);
        } else {
            return price;
        }
    }

    function updateAnswer(int256 _answer) internal {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
        latestRound++;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = block.timestamp;
        getStartedAt[latestRound] = block.timestamp;
    }

    function _setOWETH(address _oWETH) internal {
        oWETH = _oWETH;
    }

    function _setAdmin(address _admin) internal {
        admin = _admin;
    }
    // @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ private @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@ //
}
