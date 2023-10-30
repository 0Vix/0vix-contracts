pragma solidity 0.8.4;
import "../interfaces/AggregatorV3.sol";

error NotImplemented();

contract gDAIOracle is AggregatorV3 {
    AggregatorV3 daiFeed =
        AggregatorV3(0x4746DeC9e833A82EC7C2C1356372CcF2cfcD2F3D);
    address gDAI = 0x91993f2101cc758D0dEB7279d41e880F7dEFe827;

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
        (, bytes memory data) = gDAI.staticcall(
            abi.encodeWithSignature("shareToAssetsPrice()")
        );

        (, bytes memory decimalsData) = gDAI.staticcall(
            abi.encodeWithSignature("decimals()")
        );

        uint8 gDAIDecimals = uint8(toUint256(decimalsData));
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = daiFeed.latestRoundData();

        int256 price = int(
            (toUint256(data) * uint(answer)) / 10 ** gDAIDecimals
        );

        return (roundId, price, startedAt, updatedAt, answeredInRound);
    }

    function decimals() external view override returns (uint8) {
        return daiFeed.decimals();
    }

    function description() external pure override returns (string memory) {
        return "0VIX gDAI Oracle";
    }

    function version() external view override returns (uint256) {
        return daiFeed.version();
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