//SPDX-License-Identifier: MIT
pragma solidity =0.8.4;

contract TokenMock {

    mapping(address => uint256) public balances;
    mapping(address => uint256) public borrows;
    uint256 public totalSupp;
    uint256 public totalBorrow;

    function balanceOf(address user) external view returns (uint256) {
      return balances[user];
    }

    function borrowBalanceStored(address user) external view returns (uint256) {
      return borrows[user];
    }

    function totalSupply() external view returns (uint256) {
      return totalSupp;
    }

    function totalBorrows() external view returns (uint256) {
      return totalBorrow;
    }

    function setBalanceOf(address user, uint256 _balance) external {
      balances[user] = _balance;
    }

    function setBorrowBalanceStored(address user, uint256 _amount) external {
      borrows[user] = _amount;
    }

    function setTotalSupply(uint256 _amount) external {
      totalSupp = _amount;
    }

    function setTotalBorrows(uint256 _amount) external {
      totalBorrow = _amount;
    }

    
}
