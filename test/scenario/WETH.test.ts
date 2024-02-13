import { loadFixture } from '@nomicfoundation/hardhat-network-helpers'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { expect } from 'chai'
import { BigNumber } from 'ethers'
import { ethers } from 'hardhat'
import { bn, fp } from '../../common/numbers'
import { IConfig } from '../../common/configuration'
import { CollateralStatus, TradeKind } from '../../common/constants'
import {
  CTokenMock,
  SelfReferentialCollateral,
  ERC20Mock,
  IAssetRegistry,
  IFacadeTest,
  MockV3Aggregator,
  TestIBackingManager,
  TestIBasketHandler,
  TestIStRSR,
  TestIRevenueTrader,
  TestIRToken,
  WETH9,
} from '../../typechain'
import { setOraclePrice } from '../utils/oracles'
import { advanceTime } from '../utils/time'
import { getTrade } from '../utils/trades'
import {
  Collateral,
  defaultFixtureNoBasket,
  IMPLEMENTATION,
  ORACLE_ERROR,
  DECAY_DELAY,
  PRICE_TIMEOUT,
} from '../fixtures'

const DELAY_UNTIL_DEFAULT = bn('86400') // 24h

describe(`Self-referential collateral (eg ETH via WETH) - P${IMPLEMENTATION}`, () => {
  let owner: SignerWithAddress
  let addr1: SignerWithAddress
  let addr2: SignerWithAddress

  // Assets
  let collateral: Collateral[]

  // Tokens and Assets
  let weth: WETH9
  let wethCollateral: SelfReferentialCollateral
  let token0: CTokenMock
  let collateral0: Collateral
  let backupToken: ERC20Mock
  let backupCollateral: Collateral

  // Config values
  let config: IConfig

  // Contracts to retrieve after deploy
  let stRSR: TestIStRSR
  let rsr: ERC20Mock
  let rToken: TestIRToken
  let assetRegistry: IAssetRegistry
  let backingManager: TestIBackingManager
  let basketHandler: TestIBasketHandler
  let rsrTrader: TestIRevenueTrader
  let rTokenTrader: TestIRevenueTrader
  let facadeTest: IFacadeTest

  let initialBal: BigNumber
  let ethBal: BigNumber

  beforeEach(async () => {
    ;[owner, addr1, addr2] = await ethers.getSigners()
    let erc20s: ERC20Mock[]

      // Deploy fixture
    ;({
      rsr,
      stRSR,
      erc20s,
      collateral,
      config,
      rToken,
      assetRegistry,
      backingManager,
      basketHandler,
      rsrTrader,
      rTokenTrader,
      facadeTest,
    } = await loadFixture(defaultFixtureNoBasket))

    // Main ERC20
    token0 = <CTokenMock>erc20s[4] // cDai
    collateral0 = collateral[4]

    weth = await (await ethers.getContractFactory('WETH9')).deploy()
    const chainlinkFeed = <MockV3Aggregator>(
      await (await ethers.getContractFactory('MockV3Aggregator')).deploy(8, bn('1e8'))
    )
    wethCollateral = await (
      await ethers.getContractFactory('SelfReferentialCollateral')
    ).deploy({
      priceTimeout: PRICE_TIMEOUT,
      chainlinkFeed: chainlinkFeed.address,
      oracleError: ORACLE_ERROR,
      erc20: weth.address,
      maxTradeVolume: config.rTokenMaxTradeVolume,
      oracleTimeout: DECAY_DELAY,
      targetName: ethers.utils.formatBytes32String('ETH'),
      defaultThreshold: bn(0),
      delayUntilDefault: DELAY_UNTIL_DEFAULT,
    })

    // Backup
    backupToken = erc20s[2] // USDT
    backupCollateral = <Collateral>collateral[2]

    // Basket configuration
    await assetRegistry.connect(owner).register(collateral0.address)
    await assetRegistry.connect(owner).register(wethCollateral.address)
    await assetRegistry.connect(owner).register(backupCollateral.address)
    await basketHandler.setPrimeBasket([token0.address, weth.address], [fp('1'), fp('0.001')])
    await basketHandler.setBackupConfig(ethers.utils.formatBytes32String('USD'), 1, [
      token0.address,
      backupToken.address,
    ])
    await basketHandler.refreshBasket()
    await advanceTime(config.warmupPeriod.toNumber() + 1)

    await backingManager.grantRTokenAllowance(token0.address)
    await backingManager.grantRTokenAllowance(weth.address)
    await backingManager.grantRTokenAllowance(backupToken.address)

    // Mint initial balances
    initialBal = bn('1000000e18')
    await token0.connect(owner).mint(addr1.address, initialBal)
    await backupToken.connect(owner).mint(addr1.address, initialBal)
    await token0.connect(owner).mint(addr2.address, initialBal)
    await backupToken.connect(owner).mint(addr2.address, initialBal)

    // Deposit ETH to get WETH
    ethBal = bn('1e20') // 100 ETH
    await weth.connect(addr1).deposit({
      value: ethers.utils.parseUnits(ethBal.toString(), 'wei'),
    })

    // Stake RSR
    await rsr.connect(owner).mint(addr1.address, initialBal)
    await rsr.connect(addr1).approve(stRSR.address, initialBal)
    await stRSR.connect(addr1).stake(initialBal)
  })

  describe('Scenarios', function () {
    let issueAmt: BigNumber
    let cTokenAmt: BigNumber

    beforeEach(async () => {
      issueAmt = initialBal.div(100)
      cTokenAmt = issueAmt.mul(50).div(1e10) // cTokens are 50:1 with their underlying
      await token0.connect(addr1).approve(rToken.address, cTokenAmt)
      await weth.connect(addr1).approve(rToken.address, issueAmt.div(1000))
      await rToken.connect(addr1).issue(issueAmt)
      expect(await basketHandler.status()).to.equal(CollateralStatus.SOUND)
      expect(await basketHandler.fullyCollateralized()).to.equal(true)
      expect(await rToken.totalSupply()).to.equal(issueAmt)
      expect(await token0.balanceOf(backingManager.address)).to.equal(cTokenAmt)
      expect(await weth.balanceOf(backingManager.address)).to.equal(issueAmt.div(1000))
    })

    it('should sell appreciating collateral and ignore WETH', async () => {
      await token0.setExchangeRate(fp('1.1')) // 10% appreciation
      await expect(backingManager.rebalance(TradeKind.BATCH_AUCTION)).to.be.revertedWith(
        'already collateralized'
      )
      await backingManager.forwardRevenue([weth.address, token0.address])
      expect(await weth.balanceOf(rTokenTrader.address)).to.equal(0)
      expect(await weth.balanceOf(rsrTrader.address)).to.equal(0)
      await expect(
        rTokenTrader.manageTokens([weth.address], [TradeKind.BATCH_AUCTION])
      ).to.be.revertedWith('0 balance')
      await expect(rTokenTrader.manageTokens([token0.address], [TradeKind.BATCH_AUCTION])).to.emit(
        rTokenTrader,
        'TradeStarted'
      )

      // RTokenTrader should be selling token0 and buying RToken
      const trade = await getTrade(rTokenTrader, token0.address)
      expect(await trade.sell()).to.equal(token0.address)
      expect(await trade.buy()).to.equal(rToken.address)

      await expect(
        rsrTrader.manageTokens([weth.address], [TradeKind.BATCH_AUCTION])
      ).to.be.revertedWith('0 balance')
      await expect(rsrTrader.manageTokens([token0.address], [TradeKind.BATCH_AUCTION])).to.emit(
        rsrTrader,
        'TradeStarted'
      )

      // RSRTrader should be selling token0 and buying RToken
      const trade2 = await getTrade(rsrTrader, token0.address)
      expect(await trade2.sell()).to.equal(token0.address)
      expect(await trade2.buy()).to.equal(rsr.address)
    })

    it('should change basket around WETH', async () => {
      await token0.setExchangeRate(fp('0.99')) // default
      await basketHandler.refreshBasket()

      // Advance time post warmup period - SOUND just regained
      await advanceTime(Number(config.warmupPeriod) + 1)

      await expect(backingManager.rebalance(TradeKind.BATCH_AUCTION)).to.emit(
        backingManager,
        'TradeStarted'
      )

      // BackingManager shoiuld be selling token0 and buying backupToken
      const trade = await getTrade(backingManager, token0.address)
      expect(await trade.sell()).to.equal(token0.address)
      expect(await trade.buy()).to.equal(backupToken.address)

      // No WETH should have moved
      expect(await weth.balanceOf(rTokenTrader.address)).to.equal(0)
      expect(await weth.balanceOf(rsrTrader.address)).to.equal(0)
    })

    it('should redeem after ETH price increase for same quantities', async () => {
      await setOraclePrice(wethCollateral.address, bn('2e8')) // doubling of price

      // Price change should not impact share of redemption tokens
      expect(await rToken.connect(addr1).redeem(issueAmt))
      expect(await token0.balanceOf(addr1.address)).to.equal(initialBal)
      expect(await weth.balanceOf(addr1.address)).to.equal(ethBal)
    })

    it('should not default when USD price falls', async () => {
      await setOraclePrice(wethCollateral.address, bn('0.5e8')) // halving of price
      await assetRegistry.refresh()

      // Should be fully collateralized
      expect(await basketHandler.fullyCollateralized()).to.equal(true)
      expect(await basketHandler.status()).to.equal(CollateralStatus.SOUND)
      expect(await facadeTest.wholeBasketsHeldBy(rToken.address, backingManager.address)).to.equal(
        issueAmt
      )
    })

    it('should be able to deregister', async () => {
      await assetRegistry.connect(owner).unregister(wethCollateral.address)
      await basketHandler.refreshBasket()

      // Should be in disabled state, as there are no backups for WETH
      expect(await basketHandler.status()).to.equal(CollateralStatus.DISABLED)
    })
  })
})
