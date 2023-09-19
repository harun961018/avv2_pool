// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {DataTypes} from '../utils/DataTypes.sol';

interface ILendingPool {
 
  event Deposit(
    address indexed reserve,
    address user,
    address indexed onBehalfOf,
    uint256 amount,
    uint16 indexed referral
  );

  event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);

  function deposit(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode
  ) external;

  function withdraw(
    address asset,
    uint256 amount,
    address to
  ) external returns (uint256);

  function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);
}
