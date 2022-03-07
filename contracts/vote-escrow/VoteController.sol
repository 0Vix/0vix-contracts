//SPDX-License-Identifier: MIT
pragma solidity =0.8.4;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IVotingEscrow.sol";
import "../interfaces/IBoostManager.sol";
import "../interfaces/IComptroller.sol";


/**
 * @title Vote Controller
 * @author 0vix Protocol (inspired by Curve Finance)
 * @notice Controls voting for supported markets and the issuance of additinal rewards to Comptroller
 */
contract VoteController {
    // TODO sort declarations - unsorted because of using a proxy

    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private oddEpochActivities;
    EnumerableSet.AddressSet private evenEpochActivities;
    // set of the votable markets - this contract does **not** manage other non-votable 0vix markets
    EnumerableSet.AddressSet private markets;

    bool internal initialized = true; // true, because of using a proxy
    IComptroller public comp;
    IBoostManager public boostManager;

    // 7 * 86400 seconds - all future times are rounded by week
    uint256 public PERIOD; //todo set back to constant

    // Cannot change weight votes more often than once in 10 days
    uint256 public WEIGHT_VOTE_DELAY; //todo set back to constant

    uint256 public constant MULTIPLIER = 10**18;

    // everywhere in the contract percentages should have hundredths precision
    uint256 public constant HUNDRED_PERCENT = 10000;

    // emissions for the votable markets
    uint256 public totalEmissions = 0; // in wei

    uint256 public votablePercentage; // in %, hundredths precision

    // last scheduled time
    uint256 public timeTotal;
    uint256 public nextTimeRewardsUpdated;

    struct Point {
        uint256 bias;
        uint256 slope;
    }

    struct VotedSlope {
        uint256 slope;
        uint256 power;
        uint256 end;
    }

    // struct for args format when setting the fixed weights
    struct Market {
        address market;
        uint256 weight;
    }

    struct Updated {
        address market;
        uint256 reward;
        uint256 timestamp;
    }

    // to keep track of regular epoch changes and user activity lists corresponding to it
    enum Epoch {
        TO_BE_SET,
        ODD,
        EVEN
    }
    Epoch public shiftingEpoch = Epoch.TO_BE_SET;

    // Can and will be a smart contract
    address public admin;
    // Can and will be a smart contract
    address public futureAdmin;
    // Voting escrow
    address public votingEscrow;

    // track the votable 0vix markets
    mapping(address => bool) private isVotable;

    // user -> marketAddr -> VotedSlope
    mapping(address => mapping(address => VotedSlope)) public voteUserSlopes;
    // Total vote power used by user
    mapping(address => uint256) public voteUserPower;
    // Last user vote's timestamp for each market address
    mapping(address => mapping(address => uint256)) public lastUserVote;

    // marketAddr -> time -> Point
    mapping(address => mapping(uint256 => Point)) public pointsWeight;
    // marketAddr -> time -> slope
    mapping(address => mapping(uint256 => uint256)) private changesWeight;
    // marketAddr -> last scheduled time (next week)
    mapping(address => uint256) public timeWeight;

    // time -> Point
    mapping(uint256 => Point) public pointsTotal;
    // time -> slope
    mapping(uint256 => uint256) private changesSum;

    // weights of markets decided by the protocol (non-votable part of totalEmissions)
    mapping(address => uint256) public fixedRewardWeights;

    mapping(uint256 => EnumerableSet.AddressSet) private userAcitivties;

    Updated[] public updates;

    event CommitOwnership(address admin);

    event ApplyOwnership(address admin);

    event NewMarketWeight(
        address marketAddress,
        uint256 time,
        uint256 weight,
        uint256 totalWeight
    );

    event VoteForMarket(
        uint256 time,
        address user,
        address marketAddr,
        uint256 weight
    );

    event NewMarket(address addr);
    event MarketRemoved(address addr);

    event VotablePercentageChanged(
        uint256 oldPercentage,
        uint256 newPercentage
    );
    event TotalEmissionsChanged(uint256 oldAmount, uint256 newAmount);

    event FixedWeightChanged(
        address market,
        uint256 oldWeight,
        uint256 newWeight
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin only");
        _;
    }

    constructor() {}

    function initialize(
        address _votingEscrow,
        IComptroller _comptroller,
        IBoostManager _boostManager,
        uint256 _totalEmissions
    ) external {
        require(!initialized, "contract already initialized");
        require(_votingEscrow != address(0));
        require(address(_comptroller) != address(0));
        require(address(_boostManager) != address(0));

        initialized = true;
        comp = _comptroller;
        boostManager = _boostManager;
        totalEmissions = _totalEmissions;

        admin = msg.sender;
        votingEscrow = _votingEscrow;
        PERIOD = 604800;
        WEIGHT_VOTE_DELAY = 10 * 86400;
        timeTotal = (block.timestamp / PERIOD) * PERIOD;
        votablePercentage = 3000;
    }

    /**
     * @notice Transfer ownership of VoteController to `addr`
     * @param addr Address to have ownership transferred to
     * @dev admin only
     */
    function commitTransferOwnership(address addr) external onlyAdmin {
        futureAdmin = addr;
        emit CommitOwnership(addr);
    }

    /**
     * @notice Apply pending ownership transfer
     * @dev admin only
     */
    function applyTransferOwnership() external onlyAdmin {
        address _admin = futureAdmin;
        require(_admin != address(0), "admin not set");
        admin = _admin;
        emit ApplyOwnership(_admin);
    }

    /**
     * @notice Fill historic total weights week-over-week for missed checkins
     * and return the total for the future week
     * @return Total weight
     */
    function _getTotal() internal returns (uint256) {
        uint256 t = timeTotal;

        if (t == 0) return 0;

        Point memory pt = pointsTotal[t];

        for (uint256 i = 0; i < 500; i++) {
            if (t > block.timestamp) break;

            t += PERIOD;
            uint256 biasDelta = pt.slope * PERIOD;
            if (pt.bias > biasDelta) {
                pt.bias -= biasDelta;
                uint256 slopeDelta = changesSum[t];
                pt.slope -= slopeDelta;
            } else {
                pt.bias = 0;
                pt.slope = 0;
            }

            pointsTotal[t] = pt;
            if (t > block.timestamp) {
                timeTotal = t;
            }
        }

        return pt.bias;
    }

    /**
     * @notice Fill historic market weights week-over-week for missed checkins
     * and return the total for the future week
     * @param marketAddr Address of the market
     * @return Market weight
     */
    function _getWeight(address marketAddr) internal returns (uint256) {
        uint256 t = timeWeight[marketAddr];
        if (t == 0) return 0;

        Point memory pt = pointsWeight[marketAddr][t];
        for (uint256 i = 0; i < 500; i++) {
            if (t > block.timestamp) break;

            t += PERIOD;
            uint256 biasDelta = pt.slope * PERIOD;
            if (pt.bias > biasDelta) {
                pt.bias -= biasDelta;
                uint256 slopeDelta = changesWeight[marketAddr][t];
                pt.slope -= slopeDelta;
            } else {
                pt.bias = 0;
                pt.slope = 0;
            }

            pointsWeight[marketAddr][t] = pt;
            if (t > block.timestamp) timeWeight[marketAddr] = t;
        }

        return pt.bias;
    }

    /**
     * @notice Add market `addr` essentially making it votable; manual fixedWeights assignment needed
     * @dev admin only
     * @param addr Market address
     */
    function addMarket(address addr) external onlyAdmin {
        require(!isVotable[addr], "Cannot add the same market twice");
        require(comp.isMarket(addr), "address is not an 0vix market");
        isVotable[addr] = true;

        markets.add(addr);

        uint256 nextTime = ((block.timestamp + PERIOD) / PERIOD) * PERIOD;

        if (timeTotal == 0) timeTotal = nextTime;

        timeWeight[addr] = nextTime;

        emit NewMarket(addr);
    }

    /**
     * @notice Remove market `addr` essentially making it non-votable; manual fixedWeights recalibration needed
     * @dev admin only
     * @param addr Market address
     */
    function removeMarket(address addr) external onlyAdmin {
        require(isVotable[addr], "Market doesn't exist");
        isVotable[addr] = false;

        markets.remove(addr);

        // todo test what happens with market's lists (e.g. timeWeight[addr]) when re-adding

        emit MarketRemoved(addr);
    }

    /**
     * @notice Sets percentage of the emmission community can vote upon
     * @param _market Market's address
     * @param _weight Market's fixed weight with hundredth precision
     */
    function setSingleFixedRewardWeight(address _market, uint256 _weight)
        external
        onlyAdmin
    {
        Market[] memory market = new Market[](1);
        market[0] = Market(_market, _weight);
        setFixedRewardWeights(market);
    }

    /**
     * @notice Sets percentage of the emmission community can vote upon
     * @param _markets The struct containing market's address and its fixed weight with hundredth precision
     */
    function setFixedRewardWeights(Market[] memory _markets) public onlyAdmin {
        uint256 sumWeights = 0;

        for (uint256 i = 0; i < markets.length(); i++) {
            sumWeights += fixedRewardWeights[markets.at(i)];
        }

        for (uint256 i = 0; i < _markets.length; i++) {
            require(
                markets.contains(_markets[i].market),
                "Market is not in the list"
            );

            uint256 oldWeight = fixedRewardWeights[_markets[i].market];
            fixedRewardWeights[_markets[i].market] = _markets[i].weight;
            sumWeights = sumWeights - oldWeight + _markets[i].weight;

            emit FixedWeightChanged(
                _markets[i].market,
                oldWeight,
                _markets[i].weight
            );
        }

        require(sumWeights <= HUNDRED_PERCENT, "New weight(s) too high");
    }

    /**
     * @notice Checkpoint to fill data common for all markets
     */
    function checkpoint() external {
        _getTotal();
    }

    /**
     * @notice Checkpoint to fill data for both a specific market and common for all markets
     * @param addr Market address
     */
    function checkpointMarket(address addr) external {
        _getWeight(addr);
        _getTotal();
    }

    /**
     * @notice Get market relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param addr Market address
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function _marketRelativeWeight(address addr, uint256 time)
        internal
        view
        returns (uint256)
    {
        uint256 t = (time / PERIOD) * PERIOD;
        uint256 _totalWeight = pointsTotal[t].bias;

        if (_totalWeight == 0) return 0;

        uint256 _marketWeight = pointsWeight[addr][t].bias;

        return (MULTIPLIER * _marketWeight) / _totalWeight;
    }

    /**
     * @notice Get market relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param addr Market address
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function marketRelativeWeight(address addr, uint256 time)
        external
        view
        returns (uint256)
    {
        return _marketRelativeWeight(addr, time > 0 ? time : block.timestamp);
    }

    /**
     * @notice Get market weight normalized to 1e18 and also fill all the unfilled
     * values and market records
     * @dev Any address can call, however nothing is recorded if the values are filled already
     * @param addr Market address
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function marketRelativeWeightWrite(address addr, uint256 time)
        external
        returns (uint256)
    {
        _getWeight(addr);
        _getTotal();

        return _marketRelativeWeight(addr, time > 0 ? time : block.timestamp);
    }

    // Change market weight
    // Only needed when testing in reality
    function _changeMarketWeight(address addr, uint256 weight) internal {
        uint256 oldMarketWeight = _getWeight(addr);
        uint256 _totalWeight = _getTotal();
        uint256 nextTime = ((block.timestamp + PERIOD) / PERIOD) * PERIOD;

        pointsWeight[addr][nextTime].bias = weight;
        timeWeight[addr] = nextTime;

        _totalWeight = _totalWeight + weight - oldMarketWeight;
        pointsTotal[nextTime].bias = _totalWeight;
        timeTotal = nextTime;

        emit NewMarketWeight(addr, block.timestamp, weight, _totalWeight);
    }

    /**
     * @notice Change weight of market `addr` to `weight`
     * @param addr Market's address
     * @param weight New market weight
     */
    function changeMarketWeight(address addr, uint256 weight)
        external
        onlyAdmin
    {
        _changeMarketWeight(addr, weight);
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @notice Allocate voting power for changing market weights
     * @param _marketAddr Market which `msg.sender` votes for
     * @param _userWeight Weight for a market in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function voteForMarketWeights(address _marketAddr, uint256 _userWeight)
        external
    {
        require(
            shiftingEpoch != Epoch.TO_BE_SET,
            "updateRewards() was never called"
        );

        uint256 slope;
        uint256 lockEnd;
        {
            address escrow = votingEscrow;
            slope = uint256(
                int256(IVotingEscrow(escrow).get_last_user_slope(msg.sender))
            );
            lockEnd = IVotingEscrow(escrow).locked__end(msg.sender);
        }
        uint256 nextTime = ((block.timestamp + PERIOD) / PERIOD) * PERIOD;

        require(lockEnd > nextTime, "Your token lock expires too soon");
        require(
            _userWeight <= HUNDRED_PERCENT,
            "You used all your voting power"
        );

        require(
            block.timestamp >=
                (lastUserVote[msg.sender][_marketAddr] + WEIGHT_VOTE_DELAY),
            "Cannot vote so often"
        );

        require(isVotable[_marketAddr], "Market's not votable");
        // Prepare slopes and biases in memory
        VotedSlope memory oldSlope = voteUserSlopes[msg.sender][_marketAddr];
        uint256 oldBias;
        {
            uint256 oldDt;
            if (oldSlope.end > nextTime) oldDt = oldSlope.end - nextTime;

            oldBias = oldSlope.slope * oldDt;
        }
        VotedSlope memory newSlope = VotedSlope({
            slope: (slope * _userWeight) / HUNDRED_PERCENT,
            end: lockEnd,
            power: _userWeight
        });

        uint256 newDt = lockEnd - nextTime; // dev: raises when expired
        uint256 newBias = newSlope.slope * newDt;

        // Check and update powers (weights) used
        {
            uint256 powerUsed = voteUserPower[msg.sender];
            powerUsed = powerUsed + newSlope.power - oldSlope.power;
            voteUserPower[msg.sender] = powerUsed;
            require(powerUsed <= HUNDRED_PERCENT, "Used too much power");
        }

        // Remove old and schedule new slope changes
        // Remove slope changes for old slopes
        // Schedule recording of initial slope for nextTime
        {
            uint256 oldWeightBias = _getWeight(_marketAddr);
            uint256 oldSumBias = _getTotal();

            pointsWeight[_marketAddr][nextTime].bias =
                max(oldWeightBias + newBias, oldBias) -
                oldBias;
            pointsTotal[nextTime].bias =
                max(oldSumBias + newBias, oldBias) -
                oldBias;
        }

        uint256 oldWeightSlope = pointsWeight[_marketAddr][nextTime].slope;
        uint256 oldSumSlope = pointsTotal[nextTime].slope;

        if (oldSlope.end > nextTime) {
            pointsWeight[_marketAddr][nextTime].slope =
                max(oldWeightSlope + newSlope.slope, oldSlope.slope) -
                oldSlope.slope;
            pointsTotal[nextTime].slope =
                max(oldSumSlope + newSlope.slope, oldSlope.slope) -
                oldSlope.slope;
        } else {
            pointsWeight[_marketAddr][nextTime].slope += newSlope.slope;
            pointsTotal[nextTime].slope += newSlope.slope;
        }

        // Cancel old slope changes if they still didn't happen
        if (oldSlope.end > block.timestamp) {
            changesWeight[_marketAddr][oldSlope.end] -= oldSlope.slope;
            changesSum[oldSlope.end] -= oldSlope.slope;
        }

        // Add slope changes for new slopes
        changesWeight[_marketAddr][newSlope.end] += newSlope.slope;
        changesSum[newSlope.end] += newSlope.slope;

        _getTotal();

        voteUserSlopes[msg.sender][_marketAddr] = newSlope;

        //Record last action time
        lastUserVote[msg.sender][_marketAddr] = block.timestamp;

        // update the booster of the user
        boostManager.updateBoostBasis(
            msg.sender
        );

        // user has voted for the next epoch, essentially updating their booster
        // so the protocol is not able to update it while their vote counts
        if (shiftingEpoch == Epoch.ODD) {
            evenEpochActivities.add(msg.sender);
            oddEpochActivities.remove(msg.sender);
        } else {
            oddEpochActivities.add(msg.sender);
            evenEpochActivities.remove(msg.sender);
        }

        emit VoteForMarket(
            block.timestamp,
            msg.sender,
            _marketAddr,
            _userWeight
        );
    }

    /**
     * @notice Get current market weight
     * @param addr Market address
     * @return Market weight
     */
    function getMarketWeight(address addr) public view returns (uint256) {
        return pointsWeight[addr][timeWeight[addr]].bias;
    }

    /**
     * @notice Get current total weight
     * @return Total weight
     */
    function getTotalWeight() public view returns (uint256) {
        return pointsTotal[timeTotal].bias;
    }

    /**
     * @notice Sets percentage of the emmission community can vote upon
     * @param _percentage The percentage amount with hundredth precision
     */
    function setVotablePercentage(uint256 _percentage) external onlyAdmin {
        require(_percentage <= HUNDRED_PERCENT, "Maximum percentage exceeded");
        uint256 oldVotablePercentage = votablePercentage;
        votablePercentage = _percentage;
        emit VotablePercentageChanged(oldVotablePercentage, votablePercentage);
    }

    function setTotalEmissions(uint256 _totalEmissions) external onlyAdmin {
        uint256 oldEmissions = totalEmissions;
        totalEmissions = _totalEmissions;

        emit TotalEmissionsChanged(oldEmissions, totalEmissions);
    }

    function checkpointAll() internal {
        for (uint256 i = 0; i < markets.length(); i++) {
            _getWeight(markets.at(i));
        }
        _getTotal();
    }

    function updateRewards() external {
        require(
            block.timestamp >= nextTimeRewardsUpdated,
            "rewards already updated"
        );
        checkpointAll();
        nextTimeRewardsUpdated = ((block.timestamp + PERIOD) / PERIOD) * PERIOD;
        uint256 votableAmount = (totalEmissions * votablePercentage) /
            HUNDRED_PERCENT;
        uint256 fixedAmount = totalEmissions - votableAmount;

        for (uint256 i = 0; i < markets.length(); i++) {
            // todo: check if all markets have (fixed-)weights
            address addr = markets.at(i);
            uint256 relWeight = _marketRelativeWeight(addr, block.timestamp);
            uint256 reward = ((fixedAmount *
                fixedRewardWeights[markets.at(i)]) / HUNDRED_PERCENT) +
                ((votableAmount * relWeight) / 1e18);

            address[] memory addrs = new address[](1);
            addrs[0] = addr;

            uint256[] memory rewards = new uint256[](1);
            rewards[0] = reward;

            comp._setRewardSpeeds(addrs, rewards, rewards);
            updates.push(Updated(addr, reward, block.timestamp));
        }

        // shift the epoch so the booster of the needed users can be decreased
        shiftingEpoch = shiftingEpoch == Epoch.EVEN
            ? Epoch.ODD
            : Epoch(uint256(shiftingEpoch) + 1);
    }

    // update boosters for not active users
    function updateBoosters(uint256 userAmount) external {
        EnumerableSet.AddressSet storage toUpdate = shiftingEpoch == Epoch.ODD
            ? evenEpochActivities
            : oddEpochActivities;

        EnumerableSet.AddressSet storage scheduledUpdate = shiftingEpoch == Epoch.ODD
            ? oddEpochActivities
            : evenEpochActivities;

        if (userAmount == 0 || userAmount > toUpdate.length())
            userAmount = toUpdate.length();
        for (uint256 i = 0; i < userAmount; i++) {
            address account = toUpdate.at(toUpdate.length() - 1);

            // update the booster of the user
            bool boostApplies = boostManager.updateBoostBasis(
                account
            );

            // check if we need to update the booster in the next epoch's check
            if (boostApplies) {
                toUpdate.remove(account);
                scheduledUpdate.add(account);
            } else {
                toUpdate.remove(account);
            }
        }
    }

    // returns the number of users which boosters could be updated this epoch
    // can be used by any party/off-chain trigger to check if updateBoosters() function should be called
    function numOfBoostersToUpdate() external view returns (uint256) {
        EnumerableSet.AddressSet storage toUpdate = shiftingEpoch == Epoch.ODD
            ? evenEpochActivities
            : oddEpochActivities;

        return toUpdate.length();
    }

    // to satisfy the test cases
    function marketAt(uint256 index) external view returns (address) {
        return markets.at(index);
    }

    function numMarkets() external view returns (uint256) {
        return markets.length();
    }

    // dev functions
    function setPeriodHour(uint256 delayMultiplier) external onlyAdmin {
        PERIOD = 60 * 60;
        WEIGHT_VOTE_DELAY = PERIOD * delayMultiplier;
        checkpointAll();
    }

    function setPeriodWeek() external onlyAdmin {
        PERIOD = 604800;
        WEIGHT_VOTE_DELAY = 10 * 86400;
        checkpointAll();
    }

    function getUpdateLength() public view returns (uint256) {
        return updates.length;
    }

    function getAllUpdates() public view returns (Updated[] memory) {
        Updated[] memory result = new Updated[](updates.length);
        for (uint256 i = 0; i < updates.length; i++) {
            result[i] = updates[i];
        }
        return result;
    }
}