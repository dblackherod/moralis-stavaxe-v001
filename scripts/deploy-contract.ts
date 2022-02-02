import "@nomiclabs/hardhat-ethers";
import { ethers, run } from "hardhat";

async function main() {
  await run("compile");

  // assets on kovan
/*
  // wBTC.e (0x50b7545627a5162F82A992c33b87aDc75187B218)
  // wETH (0xd0a1e359811322d97991e03f863a0c30c2cf029c)
  const depositToken = '0xd0a1e359811322d97991e03f863a0c30c2cf029c' // wBTC/wETH
  // BenQi Unitroller (0x486Af39519B4Dc9a7fCcd318217352830E8AD9b4)
  const controller = '0xdee7d0f8ccc0f7ac7e45af454e5e7ec1552e8e4e'
  const qiToken = '0xe194c4c5aC32a3C9ffDb358d9Bfd523a0B6d1568'
  const rewardToken = '0x06ba82ee98b3924584f94fbd76b85f625c531078'
  // USDT-PegSwapPair (USDT-PSP) (0x98a866258926fa7042ea441f855b8e02f91ae65c
  const swapPair = '0x79fb4604f2D7bD558Cda0DFADb7d61D98b28CA9f'
 */
  // assets on avax testnet (fuji). See https://testnet.snowtrace.io/
/*
  // wBTC (0x06fc16dd05d0a10930a5db6353c3766c6103527b)
  // wBTC.e (0x385104afa0bfdac5a2bce2e3fae97e96d1cb9160)
  // wETH (0xb767287a7143759f294cfb7b1adbca1140f3de71)
  // wAVAX (0xd9d01a9f7c810ec035c0e42cb9e80ef44d7f8692)
  // qi (0xffc0ae17f671293420a0d3840e0699640f449727)
  // qiBTC (0xc185a3980abb75aa0592512bf08d9d693749af62)
  // qiBTC (mainnet) (0xe194c4c5aC32a3C9ffDb358d9Bfd523a0B6d1568)
  // qiAVAX (0x9ebfe7463eb9f162be58850d689049891ced4b62)
  // qiETH (0x22ece4437b4bb5c3e5a7cb9d7704869adf5df4a3)
  // qiUSDT (0x433b3029e906f1ee10697b9c95d98111be4aef13)
  // qiDAI (0x45bde6d14bda84f0ba309d062faf72a438aceda0)
  // YakToken (0x70617992677bdcf80bca7124bd89792a52dc5456)
  // UniSwap (0xf4e0a9224e8827de91050b528f34e2f99c82fbf6)
  // Yield Yak: AaveStrategyAvaxV1 (0xe1296be9b7d9c69ef65b054bd8ce79e326efa0d7)
  // Yield Yak: Aave AVAX (0x9254a76d964586c8117ebeb1eda39fbf1b467a26)
  // Joe Liquidity Pool Token (0x5c0be2afb63c0fafe59f615192cfce2fa7dd4571)
  // Comptroller (0x0fEC306943Ec9766C1Da78C1E1b18c7fF23FE09e)
  // Pancake Swap Token (0x9f2230459ad5C778e2a77948BE74821E992A3ee8)
 */

  const depositToken = '0x385104afa0bfdac5a2bce2e3fae97e96d1cb9160' // wETH
  const controller = '0x0fEC306943Ec9766C1Da78C1E1b18c7fF23FE09e' // rewardController
  const qiToken = '0xffc0ae17f671293420a0d3840e0699640f449727'
  const rewardToken = '0xd9d01a9f7c810ec035c0e42cb9e80ef44d7f8692'
  const swapPair = '0x9f2230459ad5C778e2a77948BE74821E992A3ee8'

 // assets on avax mainnet (avalanche). See https://snowtrace.io/
/*
  // wBTC (0x408d4cd0adb7cebd1f1a1c33a0ba2098e1295bab)
  // wBTC.e (0x50b7545627a5162F82A992c33b87aDc75187B218)
  // wETH.e (0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB)
  // wAVAX (0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7)
  // qi (0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5)
  // qiBTC (0xe194c4c5aC32a3C9ffDb358d9Bfd523a0B6d1568)
  // qiAVAX (0x5C0401e81Bc07Ca70fAD469b451682c0d747Ef1c)
  // qiETH (0x334AD834Cd4481BB02d09615E7c11a00579A7909)
  // qiUSDT (0xc9e5999b8e75C3fEB117F6f73E664b9f3C8ca65C)
  // qiDAI (0x835866d37AFB8CB8F8334dCCdaf66cf01832Ff5D)
  // YakToken (0x59414b3089ce2AF0010e7523Dea7E2b35d776ec7)
  // UniSwap (0xf4e0a9224e8827de91050b528f34e2f99c82fbf6)
  // Yield Yak: AaveStrategyAvaxV1 (0xe1296be9b7d9c69ef65b054bd8ce79e326efa0d7)
  // Yield Yak: Aave AVAX (0xAB17D37c7a05A0edf62d89E891c3333EFe5E2876)
  // Joe Liquidity Pool Token (0x454E67025631C065d3cFAD6d71E6892f74487a15)
  // Comptroller (0x486Af39519B4Dc9a7fCcd318217352830E8AD9b4)
 */

  // const depositToken = '0x50b7545627a5162F82A992c33b87aDc75187B218' // wETH
  // const controller = '0x486Af39519B4Dc9a7fCcd318217352830E8AD9b4' // rewardController
  // const qiToken = '0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5'
  // const rewardToken = '0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7'
  // const swapPair = '0x79fb4604f2D7bD558Cda0DFADb7d61D98b28CA9f'


  const [deployer, ] = await ethers.getSigners(); // add team address for the timelock contract

  const feeRecipient = deployer.address;

  // Deploy the StAVAXe contract first
  const StAVAXeVault = await ethers.getContractFactory('YakVaultStAVAXe');
  const vault = await StAVAXeVault.deploy();

  await vault.deployed();

  console.log(`🍩 Vault deployed at ${vault.address} by deployer ${deployer.address}`)

  // verify contracts at the end, so we make sure etherscan is aware of their existence
  // verify the vault
  await run("verify:verify", {
    address: vault.address,
    network: ethers.provider.network
  })

  const _timelock = await ethers.getContractFactory('YakStrategyManagerV1');
  const timelock = await _timelock.deploy(
    deployer.address, // strategy manager
    deployer.address, // strategy team
    vault.address // strategy deployer
  );

  await timelock.deployed();

  console.log(`Timelock deployed at ${timelock.address} by deployer ${deployer.address}`);

  // deploy ETH Proxy to support ETH deposit
  const ETHProxy = await ethers.getContractFactory('ETHProxy');
  const proxy = await ETHProxy.deploy(vault.address, depositToken);

  await proxy.deployed();

  console.log(`🍙 Proxy deployed at ${proxy.address}`)

  // verify the proxy
  await run("verify:verify", {
    address: proxy.address,
    network: ethers.provider.network,
    constructorArguments: [
      vault.address,
      depositToken
    ]
  })

  const ShortAction = await ethers.getContractFactory('YakStrategyStAVAXeBTC');
  const action = await ShortAction.deploy(
    'YakStrategy:BTC-StAVAXe',
    100, 50, 10000, 150,
    100, 50, 50,
    [depositToken, qiToken, rewardToken, timelock.address],
    [controller, swapPair],
    {gasPrice: 800000000000}
  );
  // const ShortAction = await ethers.getContractFactory('BenqiStrategyAvaxV2');
  // const action = await ShortAction.deploy(vault.address, depositToken, swap, controller, vaultType);

  console.log(`🍣 YakStrategy deployed at ${action.address}`)

  // verify the action
  await run("verify:verify", {
    address: action.address,
    network: ethers.provider.network,
    constructorArguments: [
      'YakStrategy:BTC-StAVAXe',
      100, 50, 10000, 150,
      100, 50, 50,
      [depositToken, qiToken, rewardToken, timelock.address],
      [controller, swapPair],
    ]
  })

  await vault["init"](
    depositToken, // asset (wbtc/weth/erc20)
    deployer.address, // owner.address,
    feeRecipient, // feeRecipient
    depositToken,
    18,
    'StAVAXe',
    'StAXe',
    [action.address]
  )
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
