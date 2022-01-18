pragma solidity ^0.5.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";

contract ERC20Mintable is ERC20, Ownable, ERC20Detailed {
    uint8 private dec = 0;
    constructor(string memory _name, string memory _symbol, uint8 _dec) public ERC20Detailed(_name, _symbol, _dec) {
        dec = _dec;
        _mint(owner(), 10000000 * (10**decimals()));
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function decimals() public view returns (uint8) {
        return dec;
    }
}