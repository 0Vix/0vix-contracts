pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ERC20Mintable is ERC20, Ownable {
    uint8 private dec = 0;
    constructor(string memory _name, string memory _symbol, uint8 _dec) ERC20(_name, _symbol) {
        dec = _dec;
        _mint(owner(), 10000000 * (10**decimals()));
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return dec;
    }
}