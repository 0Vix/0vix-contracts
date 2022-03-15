//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./OErc20.sol";
import "./interfaces/IODelegate.sol";

/**
 * @title 0VIX's OErc20Delegate Contract
 * @notice OTokens which wrap an EIP-20 underlying and are delegated to
 * @author 0VIX
 */
contract OErc20Delegate is OErc20, IODelegate {

    address public override implementation;

    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) public override {
        // Shh -- currently unused
        data;

        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            implementation = address(0);
        }

        require(msg.sender == admin, "_becomeImplementation admin only");
    }

    /**
     * @notice Called by the delegator on a delegate to forfeit its responsibility
     */
    function _resignImplementation() public override {
        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            implementation = address(0);
        }

        require(msg.sender == admin, "_resignImplementation admin only");
    }
}
