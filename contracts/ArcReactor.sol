pragma solidity 0.6.12;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./EnergyToken.sol";

interface IMigratorMaster {
    // Perform LP token migration from legacy UniswapV2 to IronSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // IronSwap must mint EXACTLY the same amount of IronSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// ArcReactor is the master of Iron. He can make ENGY and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once IRON is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract ArcReactor is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of IRONs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accIronPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accIronPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. IRONs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that IRONs distribution occurs.
        uint256 accIronPerShare; // Accumulated IRONs per share, times 1e12. See below.
    }

    // The IRON TOKEN!
    EnergyToken public iron;
    // Dev address.
    address public devaddr;
    // Block number when bonus IRON period ends.
    uint256 public bonusEndBlock;
    // Base IRON tokens created per block.
    uint256 public ironPerBlock;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorMaster public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when IRON mining starts.
    uint256 public startBlock;

    // Who Staked latest
    address public latestAddress;
    // Latest Time
    uint256 public latestTimestamp = 0;
    // Idle Seconds
    uint256 public idleDuration = 300;
    // Current Total Rewards
    uint256 public luckyRewards = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event LuckyStar(address indexed user, uint256 amount);

    constructor(
        EnergyToken _iron,
        address _devaddr,
        uint256 _ironPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        iron = _iron;
        devaddr = _devaddr;
        ironPerBlock = _ironPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accIronPerShare: 0
        }));
    }

    // Update the given pool's IRON allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorMaster _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if(_to < startBlock)
            return 0;

        if(_from < startBlock)
            _from = startBlock;

        if(_to > bonusEndBlock)
            _to = bonusEndBlock;
        
        if(_from >= _to)
            return 0;

        uint256 multipier = 0;
        if(_to == bonusEndBlock) {
            multipier = 1;
        } else {
            uint256 times = 10;
            multipier = times.sub(_to.sub(startBlock).div(bonusEndBlock.sub(startBlock).div(times)));
        }

        return _to.sub(_from).mul(multipier);
    }

    // View function to see pending IRONs on frontend.
    function pendingIron(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accIronPerShare = pool.accIronPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 ironReward = multiplier.mul(ironPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accIronPerShare = accIronPerShare.add(ironReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accIronPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
        
        sendRewards();
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 ironReward = multiplier.mul(ironPerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        //Lucky Rewards
        uint256 _rewards = ironReward.div(50);
        iron.mint(address(this), ironReward.add(_rewards));
        luckyRewards = luckyRewards.add(_rewards);

        pool.accIronPerShare = pool.accIronPerShare.add(ironReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to ArcReactor for IRON allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);
        sendRewards();

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accIronPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeIronTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);

            updateStakingTime();
        }
        user.rewardDebt = user.amount.mul(pool.accIronPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from ArcReactor.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        sendRewards();

        uint256 pending = user.amount.mul(pool.accIronPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeIronTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accIronPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe iron transfer function, just in case if rounding error causes pool to not have enough IRONs.
    function safeIronTransfer(address _to, uint256 _amount) internal {
        uint256 ironBal = iron.balanceOf(address(this));
        if (_amount > ironBal) {
            iron.transfer(_to, ironBal);
        } else {
            iron.transfer(_to, _amount);
        }
    }
    
    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    // Update who depost latest
    function updateStakingTime() internal {
        latestAddress = msg.sender;
        latestTimestamp = block.timestamp;
    }

    // Send the rewards and reset
    function sendRewards() internal {
        if(block.number < startBlock)
            return;
        
        if(block.number > bonusEndBlock)
            return;

        if(latestAddress == address(0))
            return;

        if(latestTimestamp == 0)
            return;

        if(luckyRewards == 0)
            return;
        
        if(block.timestamp - latestTimestamp > idleDuration) {
            address user = latestAddress;
            uint256 amount = luckyRewards;

            latestAddress = address(0);
            latestTimestamp = 0;
            luckyRewards = 0;

            if(amount > 0) {
                safeIronTransfer(user, amount);

                emit LuckyStar(user, amount);
            }
        }
    }
}
