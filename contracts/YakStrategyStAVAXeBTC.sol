// SPDX-License-Identifier: MIT

pragma solidity >=0.7.2;
pragma experimental ABIEncoderV2;

import "./interfaces/IBenqiERC20Delegator.sol";
import "./interfaces/IBenqiUnitroller.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IWAVAX.sol";

import "./lib/IERC20Upgradeable.sol";
import "./lib/SafeMathUpgradeable.sol";
import "./lib/MathUpgradeable.sol";
import "./lib/AddressUpgradeable.sol";
import "./lib/SafeERC20Upgradeable.sol";
import "./lib/ReentrancyGuard.sol";
import "./lib/SafeMath.sol";
import "./lib/Ownable.sol";
import "./lib/Permissioned.sol";
import "./lib/DexLibrary.sol";

import "./YakERC20.sol";
import "./YakStrategyV2.sol";

contract YakStrategyStAVAXeBTC is YakStrategyV2, ReentrancyGuard {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMath for uint256;
    using SafeMath for uint;

    // address public depositToken // Inherited from YakStrategyV2, the token the strategy wants, swaps into and tries to grow
    // address publis rewardToken // Inherited from YakStrategyV2, the token the strategy rewards
    address public qiToken; // Token we provide liquidity with (qiBTC)

    IBenqiUnitroller private rewardController;  // benqi unitroller/comptroller address
    IBenqiERC20Delegator private tokenDelegator; // use IBenqiAVAZDelegator for AVAX assets
    IRouter private router;
    IPair private swapPairToken0; // swaps rewardToken to WAVAX

    address public constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7; // wrapped AVAX
    address public constant QI = 0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5; // BENQI (QI) Token
    address public constant BTC_ROUTER = 0x60aE616a2155Ee3d9A68541Ba4544862310933d4; // BTC Router (TraderJoe)

    uint256 _balanceOfPool;
    uint private leverageLevel;
    uint private leverageBips;
    uint private minMinting;
    uint256 private redeemLimitSafetyMargin;

    event Harvest(uint256 harvested, uint256 indexed blockNumber);

    /// @notice _depositConfig[4] is _timelock contract address.
    /// @notice _strategyConfig is controller, and swapPairToken. delegator is qiToken
    /// @dev wBTC.e is 0x50b7545627a5162F82A992c33b87aDc75187B218
    /// @dev qiBTC is 0xe194c4c5aC32a3C9ffDb358d9Bfd523a0B6d1568
    /// @dev Benqi (QI) token is 0x8729438EB15e2C8B576fCc6AeCdA6A148776C0F5
    /// @dev BENQI_UNITROLLER is 0x486Af39519B4Dc9a7fCcd318217352830E8AD9b4
    /// @dev JOE_ROUTER is 0x60aE616a2155Ee3d9A68541Ba4544862310933d4
    /// @dev PANGOLIN_ROUTER is 0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106
    /// @dev see similar BenqiStrategy.sol implementations for reference
    constructor(
        string memory _name,
        uint256 _minMinting,  // minimum withdraw and borrow threshold
        uint256 _leverageLevel, // strategy leverage ratio (in % bips, 5000 = 50%)
        uint256 _leverageBips,  // strategt leverage divisor (in bips, 1000 = 10%)
        uint256 _minTokensToReinvest, //  minimum reinvestment volume (in decimals, 200)
        uint256 _adminFeeBips,  //  performance feee ratio (in % bips)
        uint256 _devFeeBips,  //  development fee ratio (in % bips)
        uint256 _reinvestRewardBips,  //  reinvestment fee ratio (in % bips)
        address[4] memory _depositConfig, // [depositToken_address, qiToken_address, rewardToken_address, timelockContract_address]
        address[2] memory _strategyConfig // [lpController_address, swapPairToken_address]
    ) {
        name = _name;
        depositToken = IERC20(_depositConfig[0]);
        qiToken = _depositConfig[1];
        rewardToken = IERC20(_depositConfig[2]); // could be YAK (0x06ba82ee98b3924584f94fbd76b85f625c531078)

        rewardController = IBenqiUnitroller(_strategyConfig[0]);
        tokenDelegator = IBenqiERC20Delegator(qiToken);
        router = IRouter(BTC_ROUTER);

        minMinting = _minMinting;
        devAddr = msg.sender;

        _updateLeverage(
            _leverageLevel,
            _leverageBips,
            _leverageBips.mul(990).div(1000) //works as long as leverageBips > 1000
        );

        _enterMarket();

        assignSwapPairSafely(_strategyConfig[1]);

        setAllowances();
        updateMinTokensToReinvest(_minTokensToReinvest);
        updateAdminFee(_adminFeeBips);
        updateDevFee(_devFeeBips);
        updateReinvestReward(_reinvestRewardBips);
        updateDepositsEnabled(true);
        transferOwnership(_depositConfig[3]); // _timelock

        /// @dev do one off approvals here
        depositToken.approve(qiToken, type(uint256).max);
        // approval for btc_router
        IERC20(QI).approve(BTC_ROUTER, type(uint256).max);

        emit Reinvest(0, 0);

    }

    function totalDeposits() public override view returns (uint) {
        (, uint256 internalBalance, uint borrow, uint256 exchangeRate) = tokenDelegator.getAccountSnapshot(address(this));
        return internalBalance.mul(exchangeRate).div(1e18).sub(borrow);
    }

    function estimateDeployedBalance() external override view returns (uint) {
        return totalDeposits();
    }

    function updateLeverage(uint256 _leverageLevel, uint256 _leverageBips, uint256 _redeemLimitSafetyMargin) external onlyDev {
      _updateLeverage(_leverageLevel, _leverageBips, _redeemLimitSafetyMargin);
      uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
      uint balance = balanceOfPool();
      _unrollDebt(balance.sub(borrowed));
      if (balance.sub(borrowed) > 0) {
          _rollupDebt(balance.sub(borrowed), 0);
      }
    }

    function setAllowances() public override onlyOwner {
        depositToken.approve(address(tokenDelegator), type(uint256).max);
        tokenDelegator.approve(address(tokenDelegator), type(uint256).max);
    }

    function deposit(uint256 amount) external override {
        _deposit(msg.sender, amount);
    }

    function depositFor(address account, uint amount) external override {
      _deposit(account, amount);
    }

    function depositWithPermit(uint amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external override {
        depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
        _deposit(msg.sender, amount);
    }

    function withdraw(uint amount) external override {
      require(amount > minMinting, "StAVAXeBtcStrategyV1:: below minimum withdraw");
      uint depositTokenAmount = _totalDepositsFresh().mul(amount).div(totalSupply);
      if (depositTokenAmount > 0) {
          _burn(msg.sender, amount);
          _withdrawDepositTokens(depositTokenAmount);
          _safeTransfer(address(depositToken), msg.sender, depositTokenAmount);
          emit Withdraw(msg.sender, depositTokenAmount);
      }
    }

    /**
     * @notice payable function needed to receive AVAX
     */
    receive() external payable {
        require(msg.sender == address(rewardController), "StAVAXeBtcStrategyV1::payments not allowed");
    }

    /// ===== View Functions =====

    /// @dev Balance of depositToken currently held in strategy positions
    function balanceOfPool() public view returns (uint256) {
        return _balanceOfPool;
    }

    /// @notice Get the balance of depositToken held idle in the Strategy
    function balanceOfDepositToken() public view returns (uint256) {
        return depositToken.balanceOf(address(this));
    }

    function getProtectedTokens()
        public
        view
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](3);
        protectedTokens[0] = address(depositToken);
        protectedTokens[1] = qiToken;
        protectedTokens[2] = address(rewardToken);
        return protectedTokens;
    }

    function checkReward() public view override returns (uint256) {
        (, , uint256 avaxRewards) = _checkRewards();
        return avaxRewards;
    }

    /// ===== Private Methods =====

    /**
     * @notice Initialization helper for Pair deposit tokens
     * @dev Checks that selected Pairs are valid for trading deposit tokens
     * @dev Assigns values to swapPairToken0 and swapPairToken1
     */
    function assignSwapPairSafely(address _swapPairToken0) private {
        require(
            _swapPairToken0 > address(0),
            "Swap pair 0 is necessary but not supplied"
        );

        require(
            address(rewardToken) == IPair(address(_swapPairToken0)).token0() ||
                address(rewardToken) == IPair(address(_swapPairToken0)).token1(),
            "Swap pair 0 does not match rewardToken0"
        );

        require(
            address(WAVAX) == IPair(address(_swapPairToken0)).token0() ||
                address(WAVAX) == IPair(address(_swapPairToken0)).token1(),
            "Swap pair 0 does not match WAVAX"
        );

        swapPairToken0 = IPair(_swapPairToken0);
    }

    /// @dev invest the asset amount
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    function _deposit(address account, uint amount) private onlyAllowedDeposits {
        require(DEPOSITS_ENABLED == true, "StAVAXeBtcStrategyV1::_deposit");
        if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
            (uint qiRewards, uint avaxRewards, uint totalQiRewards) = _checkRewards();
            if (totalQiRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
                _reinvest(qiRewards, avaxRewards, totalQiRewards);
            }
        }
        require(depositToken.transferFrom(msg.sender, address(this), amount), "StAVAXeBtcStrategyV1::transfer failed");
        uint depositTokenAmount = amount;
        uint balance = _totalDepositsFresh();
        if (totalSupply.mul(balance) > 0) {
            depositTokenAmount = amount.mul(totalSupply).div(balance);
        }
        _balanceOfPool += amount;
        _mint(account, depositTokenAmount);
        _stakeDepositTokens(amount);
        emit Deposit(account, amount);
    }

    function _stakeDepositTokens(uint amount) private {
        require(amount > 0, "StAVAXeBtcStrategyV1::_stakeDepositTokens");
        require(tokenDelegator.mint(amount) == 0, "StAVAXeBtcStrategyV1::Deposit failed");
        uint borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint principal = balanceOfPool();
        _rollupDebt(principal, borrowed);
    }

    function _withdrawDepositTokens(uint amount) private {
        _unrollDebt(amount);
        require(tokenDelegator.redeemUnderlying(amount) == 0, "StAVAXeBtcStrategyV1::redeem failed");
        uint balance = balanceOfPool();
        if (balance > 0) {
            _rollupDebt(balance, 0);
        }
    }

    /**
     * @notice Reinvest rewards from staking contract to deposit tokens
     * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
     * @param amount deposit tokens to reinvest
     */
    function _reinvest(uint qiRewards, uint avaxRewards, uint amount) private {
        uint256 _before = depositToken.balanceOf(address(this));
        uint256 _avaxBefore = address(this).balance;
        // claim QI rewards
        rewardController.claimReward(0, address(this));
        // claim AVAX rewards
        rewardController.claimReward(1, address(this));

        // swap QI -> wBTC.e
        uint256 _qiRewards = IERC20Upgradeable(QI).balanceOf(address(this));
        if (_qiRewards > 0) {
            address[] memory path = new address[](3);
            path[0] = QI;
            path[1] = WAVAX;
            path[2] = address(depositToken);

            router.swapExactTokensForTokens(
                _qiRewards,
                0,
                path,
                address(this),
                block.timestamp + 120
            );
        }

        // swap AVAX -> wBTC.e
        uint256 _avaxRewards = address(this).balance.sub(_avaxBefore);
        if (_avaxRewards > 0) {
            address[] memory path = new address[](2);
            path[0] = WAVAX;
            path[1] = address(depositToken);

            router.swapExactAVAXForTokens{
                value: _avaxRewards
            }(0, path, address(this), block.timestamp + 120);
        }

        uint256 earned = depositToken.balanceOf(address(this)).sub(_before);

        uint devFeeEarned = earned.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFeeEarned > 0) {
            _safeTransfer(address(depositToken), devAddr, devFeeEarned);
        }

        uint adminFeeEarned = earned.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        if (adminFeeEarned > 0) {
            _safeTransfer(address(depositToken), owner(), adminFeeEarned);
        }
        emit Harvest(earned, block.number);

        uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
        if (devFee > 0) {
            _safeTransfer(address(rewardToken), devAddr, devFee);
        }

        uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
        if (adminFee > 0) {
            _safeTransfer(address(rewardToken), owner(), adminFee);
        }

        uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
        if (reinvestFee > 0) {
            _safeTransfer(address(rewardToken), msg.sender, reinvestFee);
        }

        uint depositTokenAmount = _getDepositTokenAmount(amount, adminFee, devFee, reinvestFee );

        _stakeDepositTokens(depositTokenAmount);

        emit Reinvest(totalDeposits(), totalSupply);
    }

    /**
     * @notice Safely transfer using an anonymous ERC20 token
     * @dev Requires token to return true on transfer
     * @param token address
     * @param to recipient address
     * @param value amount
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        require(
            IERC20(token).transfer(to, value),
            "BenqiStrategyV1::TRANSFER_FROM_FAILED"
        );
    }

    /// ===== Core Implementations =====

    function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
        uint balanceBefore = depositToken.balanceOf(address(this));
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = tokenDelegator.balanceOfUnderlying(address(this));
        _unrollDebt(balance.sub(borrowed));
        tokenDelegator.redeemUnderlying(balanceOfPool());
        uint balanceAfter = depositToken.balanceOf(address(this));
        require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "StAVAXeBtcStrategyV1::rescueDeployedFunds");
        emit Reinvest(totalDeposits(), totalSupply);
        if (DEPOSITS_ENABLED == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }

    function reinvest() external override onlyEOA {
        (uint qiRewards, uint avaxRewards, uint totalQiRewards) = _checkRewards();
        require(totalQiRewards >= MIN_TOKENS_TO_REINVEST, "StAVAXeBtcStrategyV1::reinvest");
        _reinvest(qiRewards, avaxRewards, totalQiRewards);
    }

    /// ===== Internal Helper Functions =====

    function _totalDepositsFresh() internal returns (uint) {
        uint borrow = tokenDelegator.borrowBalanceCurrent(address(this));
        uint balance = balanceOfPool();
        return balance.sub(borrow);
    }

    function _enterMarket() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(qiToken);
        rewardController.enterMarkets(tokens);
    }

    function _updateLeverage(uint256 _leverageLevel, uint256 _leverageBips, uint256 _redeemLimitSafetyMargin) internal {
        leverageLevel = _leverageLevel;
        leverageBips = _leverageBips;
        redeemLimitSafetyMargin = _redeemLimitSafetyMargin;
    }

    function _rollupDebt(uint256 principal, uint256 borrowed) internal {
        (uint256 borrowLimit, uint256 borrowBips) = _getBorrowLimit();
        uint256 supplied = principal;
        uint256 lendTarget = principal.sub(borrowed).mul(leverageLevel).div(leverageBips);
        uint256 totalBorrowed = borrowed;
        while (supplied < lendTarget) {
            uint256 toBorrowAmount = supplied.mul(borrowLimit).div(borrowBips).sub(totalBorrowed);
            if (supplied.add(toBorrowAmount) > lendTarget) {
                toBorrowAmount = lendTarget.sub(supplied);
            }
            // safeguard needed because we can't mint below a certain threshold
            if (toBorrowAmount < minMinting) {
                break;
            }
            require(
                tokenDelegator.borrow(toBorrowAmount) == 0,
                "StAVAXeBtcStrategyV1::borrowing failed"
            );
            tokenDelegator.mint(toBorrowAmount);
            _balanceOfPool -= borrowed;
            supplied = balanceOfPool();
            totalBorrowed = totalBorrowed.add(toBorrowAmount);
        }
    }

    function _unrollDebt(uint256 amountToBeFreed) internal {
        uint256 borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
        uint256 balance = balanceOfPool();
        uint256 targetBorrow = balance
            .sub(borrowed)
            .sub(amountToBeFreed)
            .mul(leverageLevel)
            .div(leverageBips)
            .sub(balance.sub(borrowed).sub(amountToBeFreed));
        uint256 toRepay = borrowed.sub(targetBorrow);
        (uint256 borrowLimit, uint256 borrowBips) = _getBorrowLimit();
        while (toRepay > 0) {
            uint256 unrollAmount = balance.sub(borrowed.mul(borrowBips).div(borrowLimit))
         .mul(redeemLimitSafetyMargin)
         .div(leverageBips);
            if (unrollAmount > toRepay) {
                unrollAmount = toRepay;
            }
            require(
                tokenDelegator.redeemUnderlying(unrollAmount) == 0,
                "BenqiStrategyV2::failed to redeem"
            );
            tokenDelegator.repayBorrow(unrollAmount);
            _balanceOfPool += amountToBeFreed;
            balance = balanceOfPool();
            borrowed = tokenDelegator.borrowBalanceCurrent(address(this));
            if (targetBorrow >= borrowed) {
                break;
            }
            toRepay = borrowed.sub(targetBorrow);
        }
    }

    /**
     * @notice Compiler error at depositTokenAmount calculation above forces the creation
     * and use of this method. The method must be a constant method for this to work.
     */
    function _getDepositTokenAmount(uint amount, uint adminFee, uint devFee, uint reinvestFee) internal pure returns (uint) {
      return  amount.sub(devFee).sub(adminFee).sub(reinvestFee);
    }

    function _getBorrowLimit() internal view returns (uint, uint) {
        (, uint borrowLimit) = rewardController.markets(address(tokenDelegator));
        return (borrowLimit, 1e18);
    }

    function _onlyNotProtectedTokens(address _asset) internal {
        address[] memory protectedTokens = getProtectedTokens();

        for (uint256 x = 0; x < protectedTokens.length; x++) {
            require(
                address(protectedTokens[x]) != _asset,
                "Asset is protected"
            );
        }
    }

    /// @dev utility function to withdraw everything for migration
    function _withdrawAll() internal {
        tokenDelegator.redeem(balanceOfPool());
        _balanceOfPool -= balanceOfPool();
    }

    /// @dev withdraw the specified amount of depositToken, liquidate from qiToken to depositToken, and pay any debts for the conversion
    function _withdrawSome(uint256 _amount)
        internal
        returns (uint256)
    {
        if (_amount > balanceOfPool()) {
            _amount = balanceOfPool();
        }
        tokenDelegator.redeemUnderlying(_amount);
        _balanceOfPool -= _amount;

        return _amount;
    }

    function _checkRewards() internal view returns (uint qiAmount, uint avaxAmount, uint totalQiAmount) {
        uint qiRewards = _getReward(0, address(this));
        uint avaxRewards = _getReward(1, address(this));

        uint wavaxAsQI = DexLibrary.estimateConversionThroughPair(
            qiRewards, address(rewardToken), address(WAVAX), swapPairToken0
        );
        return (qiRewards, avaxRewards, avaxRewards.add(wavaxAsQI));
    }

    function _getReward(uint8 tokenIndex, address account) internal view returns (uint) {
        uint rewardAccrued = rewardController.rewardAccrued(tokenIndex, account);
        (uint224 supplyIndex, ) = rewardController.rewardSupplyState(tokenIndex, account);
        uint supplierIndex = rewardController.rewardSupplierIndex(tokenIndex, address(tokenDelegator), account);
        uint supplyIndexDelta = 0;
        if (supplyIndex > supplierIndex) {
            supplyIndexDelta = supplyIndex - supplierIndex;
        }
        uint supplyAccrued = tokenDelegator.balanceOf(account).mul(supplyIndexDelta);
        (uint224 borrowIndex, ) = rewardController.rewardBorrowState(tokenIndex, account);
        uint borrowerIndex = rewardController.rewardBorrowerIndex(tokenIndex, address(tokenDelegator), account);
        uint borrowIndexDelta = 0;
        if (borrowIndex > borrowerIndex) {
            borrowIndexDelta = borrowIndex - borrowerIndex;
        }
        uint borrowAccrued = tokenDelegator.borrowBalanceStored(account).mul(borrowIndexDelta);
        return rewardAccrued.add(supplyAccrued.sub(borrowAccrued));
    }
}
