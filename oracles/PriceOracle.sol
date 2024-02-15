//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../ktokens/interfaces/IKToken.sol";

abstract contract PriceOracle {
    /// @notice Indicator that this is a PriceOracle contract (for inspection)
    bool public constant isPriceOracle = true;

    /**
      * @notice Get the underlying price of a kToken asset
      * @param kToken The kToken to get the underlying price of
      * @return The underlying asset price mantissa (scaled by 1e18).
      *  Zero means the price is unavailable.
      */
    function getUnderlyingPrice(IKToken kToken) external virtual view returns (uint);

    /**
      * @notice Updates multiple price feeds on Pyth oracle
      * @param priceUpdateData received from Pyth network and used to update the oracle
      */
    function updateUnderlyingPrices(bytes[] calldata priceUpdateData) external virtual;
}
