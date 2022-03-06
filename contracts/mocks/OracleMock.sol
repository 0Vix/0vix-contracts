pragma solidity 0.8.4;

contract OracleMock {
    mapping(address => uint256) prices;

    constructor() public {}
    
    function getUnderlyingPrice(address oToken) public view returns (uint256) {
        return prices[oToken];
    }

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }
}
