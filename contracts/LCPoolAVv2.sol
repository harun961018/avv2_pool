// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "hardhat/console.sol";

import "./interfaces/IWETH.sol";
import "./interfaces/ISwapPlusv1.sol";
import "./interfaces/IFeeTierStrate.sol";
import "./interfaces/ILCPoolAVv2Ledger.sol";//should be changed
import "./interfaces/ILendingPool.sol";
import {DataTypes} from './utils/DataTypes.sol';
import "./utils/Ownable.sol";
import "./utils/SafeERC20.sol";
 
contract LCPoolAVv2 is Ownable {
  using SafeERC20 for IERC20;
  address public WETH;
  address public swapRouter;
  address public feeStrate;
  address public ledger;
  address public aavePool;

  bool public reinvestAble = true;
  uint256 public reinvestEdge = 100;

  struct Operator {
    address account;
    address[2] pair;
    uint256 basketId;
    address token;
    uint256 amount;
  }

  // struct swapPath {
  //   ISwapPlusv1.swapBlock[] path;
  // }


  mapping (address => bool) public managers;
  mapping (address => bool) public operators;
  modifier onlyManager() {
    require(managers[msg.sender], "LC pool: !manager");
    _;
  }

  event Deposit(uint16 poolId, uint256 liquiidty);
  event Withdraw(uint16 poolId, uint256 liquiidty, uint256 amountOut);
  event ReInvest(address token0, address token1, uint16 poolId, uint256 reward, uint256 extraLp);
  event LcFee(address account, address token, uint256 amount);
  event ClaimReward(address account, uint16 poolId, uint256 basketId, uint256 extraLp, uint256 reward);

  constructor (

    address _swapRouter,
    address _feeStrate,
    address _ledger,
    address _WETH,
    address _aavePool
  ) {
    require(_aavePool != address(0), "LC pool: aave pool");
    require(_swapRouter != address(0), "LC pool: swap router");
    require(_feeStrate != address(0), "LC pool: feeStrate");
    require(_ledger != address(0), "LC pool: ledger");
    require(_WETH != address(0), "LC pool: WETH");

    aavePool = _aavePool;
    swapRouter = _swapRouter;
    feeStrate = _feeStrate;
    ledger = _ledger;
    WETH = _WETH;
    managers[msg.sender] = true;
  }

  receive() external payable {
  }
  
  function deposit(
    Operator calldata info,
    ISwapPlusv1.swapBlock[] calldata paths
  ) public payable returns(uint256, uint256) {
    require(msg.sender == info.account || operators[msg.sender], "LC pool: no access");
    uint256[] memory dpvar = new uint256[](4);
    dpvar[0] = 0; // reward
    dpvar[1] = 0; // exLp
    dpvar[2] = 0; // rewardReserve
    dpvar[3] = 0; // iAmount

    if (info.token != address(0)) {  // If address is not null, send this amount to contract.
      dpvar[3] = IERC20(info.token).balanceOf(address(this));
      IERC20(info.token).safeTransferFrom(info.account, address(this), info.amount);
      dpvar[3] = IERC20(info.token).balanceOf(address(this)) - dpvar[3];
    }
    else {
      IWETH(WETH).deposit{value: msg.value}();
      dpvar[3] = msg.value;
    }
    
    // return extraLp, reward, reserved reward, claim extra lp, claim reward amount
    (dpvar[1], dpvar[0], dpvar[2], ,) = _reinvest(info, false);
    dpvar[3] = _distributeFee(info.basketId, (info.token==address(0)?WETH:info.token), dpvar[3], 1);
    (uint16 poolId, uint256 liquidity) = _deposit(info, dpvar[3], paths);
    ILCPoolAVv2Ledger(ledger).updateInfo(info.account, poolId, info.basketId, liquidity, dpvar[0], dpvar[2], dpvar[1], true);
    return (poolId, liquidity);
  }

  function withdraw(
    address receiver,
    Operator calldata info,
    ISwapPlusv1.swapBlock[] calldata paths
  ) public returns(uint256) {
    require(receiver == info.account || operators[msg.sender], "LC pool: no access");
    uint256[] memory wvar = new uint256[](9);
    
    // return extraLp, reward, reserved reward, claim extra lp, claim reward amount
    (wvar[1], wvar[0], wvar[2], wvar[5], wvar[6]) = _reinvest(info, true);
    wvar[8] = IERC20(info.pair[0]).balanceOf(address(this));
    if (wvar[8] < wvar[6]) {
      wvar[6] = wvar[8];
    }
    if (wvar[6] > 0) {
      IERC20(info.pair[0]).safeTransfer(info.account, wvar[6]);
    }

    bool isCoin = false;
    if (info.token == address(0)) {
      isCoin = true;
    }
    // return tokenId, withdraw liquidity amount, receive token amount
    (wvar[3], wvar[7], wvar[4]) = _withdraw(info, wvar[5], paths);
    ILCPoolAVv2Ledger(ledger).updateInfo(info.account, uint16(wvar[3]), info.basketId, wvar[7], wvar[0], wvar[2], wvar[1], false);

    wvar[4] = _distributeFee(info.basketId, isCoin?WETH:info.token, wvar[4], 0);

    if (wvar[4] > 0) {
      if (isCoin) {
        IWETH(WETH).withdraw(wvar[4]);
        (bool success, ) = payable(receiver).call{value: wvar[4]}("");
        require(success, "LC pool: Failed receipt");
      }
      else {
        IERC20(info.token).safeTransfer(receiver, wvar[4]);
      }
    }
    if (wvar[5] > 0 || wvar[6] > 0) {
      emit ClaimReward(info.account, uint16(wvar[3]), info.basketId, wvar[5], wvar[6]);
    }
    return wvar[4];
  }

  function _depositSwap(
    address tokenIn,
    uint256 amountIn,
    address[2] memory tokens,
    ISwapPlusv1.swapBlock[] calldata paths
  ) internal returns(uint256) {
    uint256 outs;
    outs = amountIn;
    if (tokenIn == address(0)) tokenIn = WETH;
    uint256 amountM = amountIn;
    if (tokenIn == tokens[0]) {
      return outs;
    }
    if (paths.length > 0) {
      _approveTokenIfNeeded(tokenIn, swapRouter, amountM);
      (, amountM) = ISwapPlusv1(swapRouter).swap(tokenIn, amountM, tokens[0], address(this), paths);
    }
    outs = amountM;
    return outs;
  }

  function _reinvest(
    Operator calldata info,
    bool claimReward
  ) internal returns(uint256, uint256, uint256, uint256, uint256) {
    uint256[] memory rvar = new uint256[](7);
    uint16 poolId = ILCPoolAVv2Ledger(ledger).poolToId(info.pair[0], info.pair[1]);
    rvar[0] = 0; //reward
    rvar[1] = 0; // extraLp
    rvar[3] = 0; // claim extra lp
    rvar[4] = 0; // claim reward amount
    if (poolId != 0) {
      rvar[5] = IERC20(info.pair[1]).balanceOf(address(this));
      rvar[6] = ILCPoolAVv2Ledger(ledger).getTVLAmount(poolId);
      if (rvar[5] > rvar[6]) {
        rvar[5] = rvar[5] - rvar[6];
        rvar[0] =_decreaseLiquidity(info.pair[0], rvar[5]);
      }
    }
    if (claimReward && poolId != 0) {
      (rvar[3], rvar[4]) = ILCPoolAVv2Ledger(ledger).getSingleReward(info.account, poolId, info.basketId, rvar[0], false);
    }
    rvar[0] += ILCPoolAVv2Ledger(ledger).getLastRewardAmount(poolId);
    rvar[0] = _distributeFee(info.basketId, info.pair[0], rvar[0], 2);
    rvar[0] = rvar[0] >= rvar[4] ? rvar[0] - rvar[4] : 0;
    rvar[2] = rvar[0]; // reserveReward need to check
    if (reinvestAble && poolId != 0 && rvar[0] >= reinvestEdge) {
      rvar[1] = _increaseLiquidity(info.pair[0], rvar[0]);
      rvar[2] = rvar[0] - rvar[1];
      emit ReInvest(info.pair[0], info.pair[1], poolId, rvar[0], rvar[1]);
    }
    return (rvar[1], rvar[0], rvar[2], rvar[3], rvar[4]);
  }

  function _deposit(
    Operator calldata info,
    uint256 iAmount,
    ISwapPlusv1.swapBlock[] calldata paths
  ) internal returns(uint16, uint256) {
    uint256 amountToSupply = _depositSwap(info.token, iAmount, info.pair, paths);
    uint16 poolId = ILCPoolAVv2Ledger(ledger).poolToId(info.pair[0], info.pair[1]); // poolId
    if (poolId == 0) {

      DataTypes.ReserveData memory reserveData = ILendingPool(aavePool).getReserveData(info.pair[0]);
      poolId = reserveData.id;
      poolId += 1;
      ILCPoolAVv2Ledger(ledger).setPoolToId(info.pair[0], info.pair[1], poolId); 
    }
    amountToSupply = _increaseLiquidity(info.pair[0], amountToSupply);
    // _refundReserveToken(info.account, info.pair[0], info.pair[1], amount0-amount[0], amount1-amount[1]);
    emit Deposit(poolId, amountToSupply);
    return (poolId, amountToSupply);
  }

  function _increaseLiquidity(
    address token,
    uint256 amountToAdd
  ) internal returns(uint256){
    uint256 addedaTokenAmount = IERC20(token).balanceOf(address(this));
    if (addedaTokenAmount > amountToAdd) {
      _approveTokenIfNeeded(token, aavePool, amountToAdd);
      ILendingPool(aavePool).deposit(token, amountToAdd, address(this), 0);
    } else {
      _approveTokenIfNeeded(token, aavePool, addedaTokenAmount);
      ILendingPool(aavePool).deposit(token, addedaTokenAmount, address(this), 0);
    }

    addedaTokenAmount -= IERC20(token).balanceOf(address(this));

    return addedaTokenAmount;
  }

  function _withdrawSwap(
    address tokenOut,
    address[2] memory tokens,
    uint256 amount,
    ISwapPlusv1.swapBlock[] memory paths
  ) internal returns(uint256) {
    uint256 outs;
    uint256 amountM = amount;
    outs = amount;
    if (tokenOut == address(0)) tokenOut = WETH;
    if (tokenOut == tokens[0]) {
      return outs;
    }
    if (paths.length > 0) {
      _approveTokenIfNeeded(tokens[0], swapRouter, amount);
      (, amountM) = ISwapPlusv1(swapRouter).swap(tokens[0], amount, tokenOut, address(this), paths);
    }

    return outs;
  }

  function _withdraw(
    Operator calldata info,
    uint256 extraLp,
    ISwapPlusv1.swapBlock[] memory paths
  ) internal returns(uint256, uint256, uint256) {
    uint16 poolId = ILCPoolAVv2Ledger(ledger).poolToId(info.pair[0], info.pair[1]);
    if (poolId == 0) {
      return (0, 0, 0);
    }
    else {
      uint256 withdrawAmount = info.amount;
      uint256 userLiquidity = ILCPoolAVv2Ledger(ledger).getUserLiquidity(info.account, poolId, info.basketId);
      if (userLiquidity < withdrawAmount) {
        withdrawAmount = userLiquidity;
      }
      uint256[] memory amount = new uint256[](2);
      withdrawAmount += extraLp;
      uint256 liquidity = IERC20(info.pair[1]).balanceOf(address(this));
      if (liquidity < withdrawAmount) {
        withdrawAmount = liquidity;
      }
      if (withdrawAmount > 0) {
        amount[0] = _decreaseLiquidity(info.pair[0], withdrawAmount);
        amount[1] = _withdrawSwap(info.token, info.pair, amount[0], paths);
        emit Withdraw(poolId, withdrawAmount, amount[1]);
        return (poolId, withdrawAmount, amount[1]);
      }
      else {
        return (poolId, withdrawAmount, 0);
      }
    }
  }

  function _decreaseLiquidity(
    address token,
    uint256 liquidity
  ) internal returns (uint256) {
    uint256 amount;
    amount = ILendingPool(aavePool).withdraw(token, liquidity, address(this));
    return amount;
  }

  function _distributeFee(uint256 basketId, address token, uint256 amount, uint256 mode) internal returns(uint256) {
    uint256[] memory fvar = new uint256[](4);
    fvar[0] = 0; // totalFee
    fvar[1] = 0; // baseFee
    if (mode == 0) {
      (fvar[0], fvar[1]) = IFeeTierStrate(feeStrate).getWithdrawFee(basketId);
    }
    else if (mode == 1) {
      (fvar[0], fvar[1]) = IFeeTierStrate(feeStrate).getDepositFee(basketId);
    }
    else if (mode == 2) {
      (fvar[0], fvar[1]) = IFeeTierStrate(feeStrate).getTotalFee(basketId);
    }

    fvar[2] = amount; // rewardReserve
    require(fvar[1] > 0, "LC pool: wrong fee configure");
    fvar[3] = amount * fvar[0] / fvar[1]; // rewardLc

    if (fvar[3] > 0) {
      uint256[] memory feeIndexs = IFeeTierStrate(feeStrate).getAllTier();
      uint256 len = feeIndexs.length;
      uint256 maxFee = IFeeTierStrate(feeStrate).getMaxFee();
      for (uint256 i=0; i<len; i++) {
        (address feeAccount, ,uint256 fee) = IFeeTierStrate(feeStrate).getTier(feeIndexs[i]);
        uint256 feeAmount = fvar[3] * fee / maxFee;
        if (feeAmount > 0 && fvar[2] >= feeAmount && IERC20(token).balanceOf(address(this)) > feeAmount) {
          IERC20(token).safeTransfer(feeAccount, feeAmount);
          emit LcFee(feeAccount, token, feeAmount);
          fvar[2] -= feeAmount;
        }
      }
    }
    return fvar[2];
  }

  function setManager(address account, bool access) public onlyOwner {
    managers[account] = access;
  }

  function setOperator(address account, bool access) public onlyManager {
    operators[account] = access;
  }

  function setFeeStrate(address _feeStrate) external onlyManager {
    require(_feeStrate != address(0), "LC pool: Fee Strate");
    feeStrate = _feeStrate;
  }

  function setSwapRouter(address _swapRouter) external onlyManager {
    require(_swapRouter != address(0), "LC pool: Swap Router");
    swapRouter = _swapRouter;
  }

  function setAavePool(address _aavePool) external onlyManager {
    require(_aavePool != address(0), "LC pool: Swap Router");
    aavePool = _aavePool;
  }

  function setReinvestInfo(bool able, uint256 edge) public onlyManager {
    reinvestAble = able;
    reinvestEdge = edge;
  }

  function _approveTokenIfNeeded(address token, address spender, uint256 amount) private {
    if (IERC20(token).allowance(address(this), spender) < amount) {
      IERC20(token).safeApprove(spender, 0);
      IERC20(token).safeApprove(spender, type(uint256).max);
    }
  }
}