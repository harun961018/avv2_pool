// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "./interfaces/IFeeTierStrate.sol";

import "./utils/Ownable.sol";
import "./interfaces/IERC20.sol";

contract LCPoolAVv2Ledger is Ownable {

  address public feeStrate;

  uint256 private constant MULTIPLIER = 1_0000_0000_0000_0000;

  // token0 -> token1 -> fee -> poolId
  mapping (address => mapping(address => uint16)) public poolToId;

  struct RewardTVLRate {
    uint256 reward;
    uint256 prevReward;
    uint256 tvl;
    uint256 rtr;
    uint256 reInvestIndex;
    bool reInvested;
    uint256 updatedAt;
  }

  struct ReinvestInfo {
    uint256 reward;
    uint256 liquidity;
    uint256 updatedAt;
  }

  struct StakeInfo {
    uint256 amount;   // Staked liquidity
    uint256 debtReward;
    uint256 rtrIndex; // RewardTVLRate index
    uint256 updatedAt;
  }

  // account -> poolId -> basketId -> info basketid=0?lcpool
  mapping (address => mapping (uint16 => mapping (uint256 => StakeInfo))) public userInfo;
  // poolid => info
  mapping (uint16 => RewardTVLRate[]) public poolInfoAll;
  // poolid -> reinvest
  mapping (uint16 => ReinvestInfo[]) public reInvestInfo;

  mapping (address => bool) public managers;
  modifier onlyManager() {
    require(managers[msg.sender], "LC pool ledger: !manager");
    _;
  }

  constructor (
    address _feeStrate
  ) {
    require(_feeStrate != address(0), "LC pool ledger: feeStrate");

    feeStrate = _feeStrate;
    managers[msg.sender] = true;
  }

  function setPoolToId(address token0, address token1, uint16 id) public onlyManager {
    poolToId[token0][token1] = id;
  }

  function getLastRewardAmount(uint16 poolId) public view returns(uint256) {
    if (poolId != 0 && poolInfoAll[poolId].length > 0) {
      return poolInfoAll[poolId][poolInfoAll[poolId].length-1].prevReward;
    }
    return 0;
  }
  function getTVLAmount(uint16 poolId) public view returns(uint256) {
    if (poolId != 0 && poolInfoAll[poolId].length > 0) {
      return poolInfoAll[poolId][poolInfoAll[poolId].length-1].tvl;
    }
    return 0;
  }

  function getUserLiquidity(address account, uint16 poolId, uint256 basketId) public view returns(uint256) {
    return userInfo[account][poolId][basketId].amount;
  }

  function updateInfo(address acc, uint16 pId, uint256 bId, uint256 liquidity, uint256 reward, uint256 rewardAfter, uint256 exLp, bool increase) public onlyManager {
    uint256[] memory ivar = new uint256[](6);
    ivar[0] = 0;      // prevTvl
    ivar[1] = 0;      // prevTotalReward
    ivar[2] = reward; // blockReward
    ivar[3] = 0;      // exUserLp
    ivar[4] = 0;      // userReward
    ivar[5] = 0;      // rtr
    if (poolInfoAll[pId].length > 0) {
      RewardTVLRate memory prevRTR = poolInfoAll[pId][poolInfoAll[pId].length-1];
      ivar[0] = prevRTR.tvl;
      ivar[1] = prevRTR.reward;
      ivar[2] = (ivar[2] >= prevRTR.prevReward) ? (ivar[2] - prevRTR.prevReward) : 0;
      ivar[5] = prevRTR.rtr;
    }
    ivar[5] += (ivar[0] > 0 ? ivar[2] * MULTIPLIER / ivar[0] : 0);
    
    (ivar[3], ivar[4]) = getSingleReward(acc, pId, bId, reward, false);

    bool reInvested = false;
    if (exLp > 0) {
      ReinvestInfo memory tmp = ReinvestInfo({
        reward: reward,
        liquidity: exLp,
        updatedAt: block.timestamp
      });
      reInvestInfo[pId].push(tmp);
      reInvested = true;
      ivar[3] += ivar[4] * exLp / reward;
      ivar[0] += exLp;
      userInfo[acc][pId][bId].amount += ivar[3];
      ivar[4] = 0;
    }

    RewardTVLRate memory tmpRTR = RewardTVLRate({
      reward: ivar[1] + ivar[2],
      prevReward: rewardAfter,
      tvl: increase ? ivar[0] + liquidity : (ivar[0] >= liquidity ? ivar[0] - liquidity : 0),
      rtr: ivar[5],
      reInvestIndex: reInvestInfo[pId].length,
      reInvested: reInvested,
      updatedAt: block.timestamp
    });
    poolInfoAll[pId].push(tmpRTR);
    
    if (increase) {
      userInfo[acc][pId][bId].amount += liquidity;
      userInfo[acc][pId][bId].debtReward = ivar[4];
    }
    else {
      if (userInfo[acc][pId][bId].amount >= liquidity) {
        userInfo[acc][pId][bId].amount -= liquidity;
      }
      else {
        userInfo[acc][pId][bId].amount = 0;
      }
      userInfo[acc][pId][bId].debtReward = 0;
    }
    userInfo[acc][pId][bId].rtrIndex = poolInfoAll[pId].length - 1;
    userInfo[acc][pId][bId].updatedAt = block.timestamp;
  }

  function getSingleReward(address acc, uint16 pId, uint256 bId, uint256 currentReward, bool cutfee) public view returns(uint256, uint256) {
    uint256[] memory jvar = new uint256[](7);
    jvar[0] = 0;  // extraLp
    jvar[1] = userInfo[acc][pId][bId].debtReward; // reward
    jvar[2] = userInfo[acc][pId][bId].amount;     // stake[j]
    jvar[3] = 0; // reward for one stage

    if (jvar[2] > 0) {
      uint256 t0 = userInfo[acc][pId][bId].rtrIndex;
      uint256 tn = poolInfoAll[pId].length;
      uint256 index = t0;
      while (index < tn) {
        if (poolInfoAll[pId][index].rtr >= poolInfoAll[pId][t0].rtr) {
          jvar[3] = (jvar[2] + jvar[0]) * (poolInfoAll[pId][index].rtr - poolInfoAll[pId][t0].rtr) / MULTIPLIER;
        }
        else {
          jvar[3] = 0;
        }
        if (poolInfoAll[pId][index].reInvested) {
          jvar[0] += jvar[3] * reInvestInfo[pId][poolInfoAll[pId][index].reInvestIndex-1].liquidity / reInvestInfo[pId][poolInfoAll[pId][index].reInvestIndex-1].reward;
          t0 = index;
          jvar[3] = 0;
        }
        index ++;
      }
      jvar[1] += jvar[3];

      if (poolInfoAll[pId][tn-1].tvl > 0 && currentReward >= poolInfoAll[pId][tn-1].prevReward) {
        jvar[1] = jvar[1] + (jvar[2] + jvar[0]) * (currentReward - poolInfoAll[pId][tn-1].prevReward) / poolInfoAll[pId][tn-1].tvl;
      }
    }

    if (cutfee == false) {
      return (jvar[0], jvar[1]);
    }

    (jvar[4], jvar[5]) = IFeeTierStrate(feeStrate).getTotalFee(bId);
    require(jvar[5] > 0, "LC pool ledger: wrong fee configure");
    jvar[6] = jvar[1] * jvar[4] / jvar[5]; // rewardLc

    if (jvar[6] > 0) {
      uint256[] memory feeIndexs = IFeeTierStrate(feeStrate).getAllTier();
      uint256 len = feeIndexs.length;
      uint256 maxFee = IFeeTierStrate(feeStrate).getMaxFee();
      for (uint256 i=0; i<len; i++) {
        (, ,uint256 fee) = IFeeTierStrate(feeStrate).getTier(feeIndexs[i]);
        uint256 feeAmount = jvar[6] * fee / maxFee;
        if (feeAmount > 0 && jvar[1] >= feeAmount) {
          jvar[1] -= feeAmount;
        }
      }
    }

    return (jvar[0], jvar[1]);
  }

  function getReward(address account, uint16[] memory poolId, uint256[] memory basketIds, address[] memory aToken, address lcPoolAVv3) public view
    returns(uint256[] memory, uint256[] memory)
  {
    uint256 bLen = basketIds.length;
    uint256 len = poolId.length * bLen;
    uint256[] memory extraLp = new uint256[](len);
    uint256[] memory reward = new uint256[](len);
    for (uint256 x = 0; x < poolId.length; x ++) {
      uint256 aTokenBalance = IERC20(aToken[x]).balanceOf(lcPoolAVv3);
      uint256 depositedAmount = getTVLAmount(poolId[x]);
      uint256 currentReward = (aTokenBalance > depositedAmount? aTokenBalance - depositedAmount : 0);
      if (poolInfoAll[poolId[x]].length > 0) {
        currentReward += poolInfoAll[poolId[x]][poolInfoAll[poolId[x]].length-1].prevReward;
      }
      for (uint256 y = 0; y < bLen; y ++) {
        (extraLp[x*bLen + y], reward[x*bLen + y]) = getSingleReward(account, poolId[x], basketIds[y], currentReward, true);
      }
    }
    return (extraLp, reward);
  }

  function poolInfoLength(uint16 poolId) public view returns(uint256) {
    return poolInfoAll[poolId].length;
  }

  function reInvestInfoLength(uint16 poolId) public view returns(uint256) {
    return reInvestInfo[poolId].length;
  }

  function setManager(address account, bool access) public onlyOwner {
    managers[account] = access;
  }

  function setFeeStrate(address _feeStrate) external onlyManager {
    require(_feeStrate != address(0), "LC pool ledger: Fee Strate");
    feeStrate = _feeStrate;
  }
}   
