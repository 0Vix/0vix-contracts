//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "../openzeppelin@4.5.0/transparent/TransparentUpgradeableProxy.sol";

contract TransparentProxy is TransparentUpgradeableProxy {
    constructor(address logic, address admin, bytes memory data) payable TransparentUpgradeableProxy(logic, admin, data) {}
}