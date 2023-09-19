// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

interface ILCPoolAVv2Ledger {
  // token0 -> token1 -> fee -> poolId
  function poolToId(address token0, address token1) external view returns(uint16);
  function getTVLAmount(uint16 poolId) external view returns(uint256);
  function setPoolToId(address token0, address token1, uint16 id) external;
  function getLastRewardAmount(uint16 poolId) external view returns(uint256);
  function getUserLiquidity(address account, uint16 poolId, uint256 basketId) external view returns(uint256);
 
  function updateInfo(
    address acc,
    uint16 tId,
    uint256 bId,
    uint256 liquidity,
    uint256 reward0,
    uint256 reward1,
    uint256 exLp,
    bool increase
  ) external;

  function getSingleReward(address acc, uint16 tId, uint256 bId, uint256 currentReward, bool cutfee)
    external view returns(uint256, uint256);
  function getReward(address account, uint16[] memory poolId, uint256[] memory basketIds, address[] memory aToken, address lcPoolAVv3) external view
    returns(uint256[] memory, uint256[] memory);
  function poolInfoLength(uint16 poolId) external view returns(uint256);
  function reInvestInfoLength(uint16 poolId) external view returns(uint256);
}
