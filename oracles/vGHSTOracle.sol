pragma solidity 0.8.4;
import "./interfaces/AggregatorV3.sol";

error NotImplemented();

contract VGHSTOracle is AggregatorV3 {
    // GHST Feed
    AggregatorV3 constant ghstFeed =
        AggregatorV3(0xDD229Ce42f11D8Ee7fFf29bDB71C7b81352e11be);

    // vGHST Feed
    address constant vGHST = 0x51195e21BDaE8722B29919db56d95Ef51FaecA6C;

    constructor() {}

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert NotImplemented();
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (bool success, bytes memory data) = vGHST.staticcall(
            abi.encodeWithSignature("convertVGHST(uint256)", 1 ether)
        );

        require(success, "vGHST#convertVGHST() reverted");

        (, bytes memory decimalsData) = vGHST.staticcall(
            abi.encodeWithSignature("decimals()")
        );

        uint8 vGHSTDecimals = uint8(toUint256(decimalsData));
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = ghstFeed.latestRoundData();
 
        int256 price = int(
            (toUint256(data) * uint(answer)) / 10 ** vGHSTDecimals
        );


        return (roundId, price, startedAt, updatedAt, answeredInRound);
    }

    function decimals() external view override returns (uint8) {
        return ghstFeed.decimals();
    }

    function description() external pure override returns (string memory) {
        return "0VIX vGHST Oracle";
    }

    function version() external view override returns (uint256) {
        return ghstFeed.version();
    }

    // UTILS
    function toUint256(
        bytes memory _bytes
    ) internal pure returns (uint256 value) {
        assembly {
            value := mload(add(_bytes, 0x20))
        }
        return value;
    }
}