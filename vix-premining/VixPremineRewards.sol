// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import {IERC20MetadataUpgradeable as IERC20} from "@openzeppelin/contracts-upgradeable/interfaces/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract VixPremineRewards is OwnableUpgradeable, PausableUpgradeable {
  mapping(address => uint256) public userRewards;
  mapping(address => uint256) public marketRewards;
  address[] public allMarkets;
  address public vixToken;

  struct User {
    address userAddress;
    uint256 rewardsThisEpoch;
  }
  struct Market {
    address marketAddress;
    uint256 rewardsThisEpoch;
  }

  //************ * ฅ^•ﻌ•^ฅ  𝑰𝑵𝑰𝑻  ฅ^•ﻌ•^ฅ * ************//
  function initialize() external initializer {
    __Ownable_init();
    _pause();
  }

  //************ * ฅ^•ﻌ•^ฅ  USERS INTERACTION  ฅ^•ﻌ•^ฅ * ************//
  function claimVixReward() external whenNotPaused {
    uint256 rewards = userRewards[msg.sender];
    require(rewards > 0, "No Rewards");
    userRewards[msg.sender] = 0;
    IERC20(vixToken).transfer(msg.sender, rewards);
    emit CollectedRewards(msg.sender, rewards);
  }

  //************ * ฅ^•ﻌ•^ฅ  ONLY OWNER  ฅ^•ﻌ•^ฅ * ************//

  function pause() external onlyOwner {
    _pause();
  }

  function unpause() external onlyOwner {
    _unpause();
  }

  function setVixToken(address _vixAddress) external onlyOwner {
    vixToken = _vixAddress;
    emit SetVixToken(_vixAddress);
  }

  function setMarkets(address[] memory _markets) external onlyOwner {
    allMarkets = _markets;
    emit SetAllMarkets(_markets);
  }

  function setRewardsForMarkets(Market[] memory _markets, uint256 _epoch)
    external
    onlyOwner
  {
    uint256 length = _markets.length;
    for (uint256 i = 0; i < length; ) {
      Market memory market = _markets[i];
      marketRewards[market.marketAddress] = market.rewardsThisEpoch;
      unchecked {
        ++i;
      }
      emit SetMarketRewards(
        market.marketAddress,
        market.rewardsThisEpoch,
        _epoch
      );
    }
  }

  function addRewards(User[] memory _userAmounts, uint256 _epoch)
    external
    onlyOwner
  {
    uint256 length = _userAmounts.length;
    User memory user;
    for (uint256 i = 0; i < length; ) {
      user = _userAmounts[i];
      userRewards[user.userAddress] += user.rewardsThisEpoch;
      unchecked {
        ++i;
      }
    }
    emit AddedRewards(_epoch);
  }

  ///@dev Careful this will replace user amounts
  function editRewards(User[] memory _editedUserAmounts) external onlyOwner {
    uint256 length = _editedUserAmounts.length;
    for (uint256 i = 0; i < length; ) {
      User memory user = _editedUserAmounts[i];
      userRewards[user.userAddress] = user.rewardsThisEpoch;
      unchecked {
        ++i;
      }
    }
  }

  //************ * ฅ^•ﻌ•^ฅ  VIEW  ฅ^•ﻌ•^ฅ * ************//

  function getAllMarketRewards() public view returns (Market[] memory) {
    uint256 length = allMarkets.length;
    Market[] memory markets = new Market[](length);
    for (uint256 i = 0; i < length; ) {
      address marketAddress = allMarkets[i];
      uint256 marketReward = marketRewards[marketAddress];
      markets[i] = Market(marketAddress, marketReward);
      unchecked {
        ++i;
      }
    }
    return markets;
  }

  //************ * ฅ^•ﻌ•^ฅ  𝑬𝑽𝑬𝑵𝑻𝑺  ฅ^•ﻌ•^ฅ * ************//

  event AdjustedReward(address indexed userAddress, uint256 adjustedReward);
  event AddedRewards(uint256 epoch);
  event CollectedRewards(address indexed userAddress, uint256 amount);
  event SetVixToken(address vixAddress);
  event SetAllMarkets(address[] allMarkets);
  event SetMarketRewards(
    address indexed market,
    uint256 rewardsThisEpoch,
    uint256 indexed epoch
  );
}
