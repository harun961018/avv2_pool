// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {DataTypes} from '../utils/DataTypes.sol';
interface IPool {

  event Supply(
    address indexed reserve,
    address user,
    address indexed onBehalfOf,
    uint256 amount,
    uint16 indexed referralCode
  );

  event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);

  function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

  function supplyWithPermit(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode,
    uint256 deadline,
    uint8 permitV,
    bytes32 permitR,
    bytes32 permitS
  ) external;

  function withdraw(address asset, uint256 amount, address to) external returns (uint256);

  /**
   * @notice Validates and finalizes an aToken transfer
   * @dev Only callable by the overlying aToken of the `asset`
   * @param asset The address of the underlying asset of the aToken
   * @param from The user from which the aTokens are transferred
   * @param to The user receiving the aTokens
   * @param amount The amount being transferred/withdrawn
   * @param balanceFromBefore The aToken balance of the `from` user before the transfer
   * @param balanceToBefore The aToken balance of the `to` user before the transfer
   */
  function finalizeTransfer(
    address asset,
    address from,
    address to,
    uint256 amount,
    uint256 balanceFromBefore,
    uint256 balanceToBefore
  ) external;

  function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);

}
