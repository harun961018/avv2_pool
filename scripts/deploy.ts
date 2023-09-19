import { ethers } from "hardhat";
//  const hre = require("hardhat") ;
async function main() {
  // const _feeStrate = "0xA66F49F5F5529b5D04266AD966c39564f6aCFDD2";
  const WETH =       "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9";
  const swapRouter = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9";
  const aavePool =   "0x4bd5643ac6f66a5237E18bfA7d47cF22f1c9F210";
  const _feeStrate = await ethers.deployContract("FeeTierStrate");

  await _feeStrate.waitForDeployment();

  const LCPoolAVv2Ledger = await ethers.deployContract("LCPoolAVv2Ledger", [_feeStrate]);

  await LCPoolAVv2Ledger.waitForDeployment();

  const LCPoolAVv2 = await ethers.deployContract("LCPoolAVv2", [[swapRouter, _feeStrate, LCPoolAVv2Ledger, WETH, aavePool]]);

  console.log(
    `Lock with ${ethers.formatEther(
      lockedAmount
    )}ETH and unlock timestamp ${unlockTime} deployed to ${lock.target}`
  );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
