//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../interfaces/IKErc20.sol";


abstract contract KErc20Storage is IKErc20 {
    /**
     * @notice Underlying asset for this KToken
     */
    address public override underlying;
}
