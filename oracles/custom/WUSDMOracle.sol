// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { VaultOraclePyth, IPyth, SD59x18 } from "./abstract/VaultOraclePyth.sol";
import { FullMath } from "../../libraries/FullMath.sol";
import { IUniswapV3PoolState } from "../../interfaces/IUniswapV3PoolState.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title wUSDMOracle - Wrapped Mountain Protocol USD Oracle
 * @author KEOM Protocol
 * @dev An EMA-based Oracle contract for the USDM market.
 */
contract WUSDMOracle is VaultOraclePyth {
    IUniswapV3PoolState private immutable USDMUSDC =
        IUniswapV3PoolState(0x177B0D886f673a0d1dF92a906689068394e1B5Af);
    uint256 private immutable token0Decimals = 10 ** 6; // usdc

    constructor(
        address _underlyingToken,
        IPyth _pyth,
        bytes32 _tokenId,
        SD59x18 _span,
        uint256 _deviationThreshold,
        uint256 _maxDT,
        uint256 _minDT
    )
        VaultOraclePyth(
            _underlyingToken,
            _pyth,
            _tokenId,
            _span,
            _deviationThreshold,
            _maxDT,
            _minDT
        )
    {}

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function description() external pure returns (string memory) {
        return "KEOM Wrapped Mountain Protocol USD Oracle";
    }

    function getNewObs() public view override returns (uint256) {
        (uint160 sqrtPriceX96, , , , , , ) = USDMUSDC.slot0();
        return
            FullMath.mulDiv(
                uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
                token0Decimals,
                1 << 192
            );
    }

    function getUnderlyingDecimals() public view override returns (uint8) {
        return ERC20(underlyingToken).decimals();
    }
}
