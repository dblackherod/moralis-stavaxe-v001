// SPDX-License-Identifier: MIT
pragma solidity >=0.7.2;
pragma experimental ABIEncoderV2;

import "./lib/ReentrancyGuardUpgradeable.sol";
import "./lib/ERC20Upgradeable.sol";
import "./lib/OwnableUpgradeable.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/vaults/IWETH.sol";
import "./lib/SafeERC20.sol";
import "./lib/SafeMath.sol";

import "./YakERC20.sol";
import "./YakRegistry.sol";
import "./YakStrategy.sol";

contract YakVaultStAVAXe is ERC20Upgradeable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  enum VaultState {Locked, Unlocked, Emergency}

  /// @dev current vault state
  VaultState public state;

  /// @dev vault state before it was paused
  VaultState public stateBeforePause;

  /// @notice YakRegistry address
  YakRegistry public yakRegistry;

  /// @dev 100%
  uint256 public constant BASE = 10000;

  /// @dev percentage profits for the fee recipient
  uint256 public performanceFeeInPercent = 100; // 1%

  /// @dev percentage of total asset charged as annual management fee
  uint256 public managementFeeInPercent = 50; // 0.5%

  /// @dev amount of asset registered for withdrawal. Reserved in vault after current round ends
  uint256 public withdrawQueueAmount;

  /// @dev amount of asset deposited into the vault, but hasn't minted a share yet
  uint256 public pendingDeposit;

  /// @dev address of WETH (Reward)
  address public WETH;

  /// @dev ERC20 asset which can be deposited into this strategy. Nothing but ERC20s.
  address public asset;

  /// @dev fees recipient address
  address public feeRecipient;

  /// @dev vault strategies
  address[] public strategies;

  /// @dev current round start timestamp
  uint256 public currentRoundStartTimestamp;

  /// @dev current round starting capital
  uint256 public currentRoundStartingAmount;

  /// @dev vault capitalization (Maximum TVL)
  uint256 public cap = 1000 ether;

  /// @dev
  uint256 public constant minimumRuntime = 18 hours;

  /// @dev current round
  uint256 public round;

  /// @dev user share in withdraw queue for a round
  mapping(address => mapping(uint256 => uint256)) public userRoundQueuedWithdrawShares;

  /// @dev user asset amount in deposit queue for a round
  mapping(address => mapping(uint256 => uint256)) public userRoundQueuedDepositAmount;

  /// @dev total registered shares per round
  mapping(uint256 => uint256) public roundTotalQueuedWithdrawShares;

  /// @dev total asset recorded at end of each round
  mapping(uint256 => uint256) public roundTotalAsset;

  /// @dev total share supply recorded at end of each round
  mapping(uint256 => uint256) public roundTotalShare;

  /*=====================
   *       Events       *
   *====================*/

  event Deposit(address account, uint256 amountDeposited, uint256 shareMinted);

  event Withdraw(address account, uint256 amountWithdrawn, uint256 shareBurned);

  event WithdrawFromQueue(address account, uint256 amountWithdrawn, uint256 round);

  event Rollover(uint256[] allocations);

  event StateUpdated(VaultState state);

  event CapUpdated(uint256 newCap);

  event Sync(uint newTotalDeposits, uint newTotalSupply);

  event AddStrategy(address indexed strategy);

  /*=====================
   *     Modifiers      *
   *====================*/

  /**
   * @dev can only be executed in the unlocked state.
   */
  modifier onlyUnlocked {
    require(state == VaultState.Unlocked, "!Unlocked");
    _;
  }

  /**
   * @dev can only be executed in the locked state.
   */
  modifier onlyLocked {
    require(state == VaultState.Locked, "!Locked");
    _;
  }

  /**
   * @dev can only be executed in the unlocked state. Sets the state to 'Locked'
   */
  modifier lockState {
    state = VaultState.Locked;
    emit StateUpdated(VaultState.Locked);
    _;
  }

  /**
   * @dev Sets the state to 'Unlocked'
   */
  modifier unlockState {
    state = VaultState.Unlocked;
    emit StateUpdated(VaultState.Unlocked);
    _;
  }

  /**
   * @dev can only be executed if vault is not in the 'Emergency' state.
   */
  modifier notEmergency {
    require(state != VaultState.Emergency, "Emergency");
    _;
  }

  /*=====================
   * External Functions *
   *====================*/

  /**
   * @notice function to init the vault
   * this will set the "action" for this strategy vault and won't be able to change
   * @param _asset The asset that this vault will manage. Cannot be changed after initializing.
   * @param _owner The address that will be the owner of this vault.
   * @param _feeRecipient The address to which all the fees will be sent. Cannot be changed after initializing.
   * @param _weth address of WETH
   * @param _decimals of the _asset
   * @param _tokenName name of the share given to depositors of this vault
   * @param _tokenSymbol symbol of the share given to depositors of this vault
   * @param _strategies array of addresses of the strategy contracts
   * @dev when choosing strategies make sure they have similar lifecycles and expiries. if the strategies can't all be closed at the
   * same time, composing them may lead to tricky interactions like user funds being stuck for longer in strategies than expected.
   */
  function init(
    address _asset,
    address _owner,
    address _feeRecipient,
    address _weth,
    uint8 _decimals,
    string memory _tokenName,
    string memory _tokenSymbol,
    address _registry,
    address[] memory _strategies
  ) public initializer {
    __ReentrancyGuard_init();
    __ERC20_init(_tokenName, _tokenSymbol);
    _setupDecimals(_decimals);
    __Ownable_init();
    transferOwnership(_owner);

    asset = _asset;
    feeRecipient = _feeRecipient;
    WETH = _weth;

    yakRegistry = YakRegistry(_registry);

    // assign strategies
    for (uint256 i = 0; i < _strategies.length; i++) {
      // check all items before strategies[i], does not equal to strategy[i]
      for (uint256 j = 0; j < i; j++) {
        require(_strategies[i] != _strategies[j], "duplicate Strategy");
      }
      strategies.push(_strategies[i]);
      emit AddStrategy(_strategies[i]);
    }

    yakRegistry.addStrategies(strategies);

    state = VaultState.Unlocked;

    currentRoundStartTimestamp = block.timestamp;
  }

  /**
   * @notice allow vault owner to change vault cap
   * @param _cap the new cap of the vault
   */
  function setCap(uint256 _cap) external onlyOwner {
    cap = _cap;
    emit CapUpdated(cap);
  }

  /**
   * @notice total assets controlled by this vault, excluding pending deposit and withdraw
   */
  function totalAsset() external view returns (uint256) {
    return _netAssetsControlled();
  }

  /**
   * @notice how many shares a user can get if they deposit `_amount` of asset in vault
   * @dev this number will change when someone registers a withdraw when the vault is locked
   * @param _amount asset amount the user will deposit
   */
  function getSharesByDepositAmount(uint256 _amount) external view returns (uint256) {
    return _getSharesByDepositAmount(_amount, _netAssetsControlled());
  }

  /**
   * @notice how much asset a user can get back if they burn `_shares` amount of shares.
   * Amount returned also deducts fees.
   * @param _shares shares amount the user will burn
   */
  function getWithdrawAmountByShares(uint256 _shares) external view returns (uint256) {
    return _getWithdrawAmountByShares(_shares);
  }

  /**
   * @notice deposit `amount` of asset into vault and issues shares
   * @dev deposit ERC20 asset and get shares. Direct deposits can only happen when the vault is unlocked.
   * @param _amount asset amount deposited.
   */
  function deposit(uint256 _amount) external onlyUnlocked {
    IERC20(asset).safeTransferFrom(msg.sender, address(this), _amount);
    _deposit(_amount);
  }

  /**
   * @notice deposit `amount` of asset into vault without issuing shares
   * @dev deposits the ERC20 asset into the pending queue. This is called when the vault is locked.
   * @note if a user deposits before the start of the end of the current round, they will not be able to withdraw their
   * funds until the current round is over. They will also not be able to earn any premiums on their current deposit.
   * @param _amount asset amount deposited.
   */
  function registerDeposit(uint256 _amount, address _shareRecipient) external onlyLocked {
    IERC20(asset).safeTransferFrom(msg.sender, address(this), _amount);
    uint256 totalWithDepositedAmount = _totalAssets();
    require(totalWithDepositedAmount < cap, "Cap exceeded");
    userRoundQueuedDepositAmount[_shareRecipient][round] = userRoundQueuedWithdrawShares[_shareRecipient][round].add(
      _amount
    );
    pendingDeposit = pendingDeposit.add(_amount);
  }

  /**
   * @notice anyone can call this function to actually transfer minted shares to depositors
   * @dev this can only be called once closePosition is called to end the current round.
   * @dev Depositor needs a shareto be able to withdraw their assets in the future.
   * @param _depositor depositor address
   * @param _round the round which depositor called `registerDeposit`
   */
  function claimShares(address _depositor, uint256 _round) external {
    require(_round < round, "Invalid round");
    uint256 amountDeposited = userRoundQueuedDepositAmount[_depositor][_round];

    userRoundQueuedDepositAmount[_depositor][_round] = 0;

    uint256 equivalentShares = amountDeposited.mul(roundTotalShare[_round]).div(roundTotalAsset[_round]);

    // transfer shares from vault to user
    _transfer(address(this), _depositor, equivalentShares);
  }

  /**
   * @notice withdraw asset from vault using vault shares.
   * @dev msg.sender needs to burn vault shares to be able to withdraw.
   * If the user called `registerDeposit` without someone calling `claimShares` for them, they wont be able to withdraw.
   * They need to have the shares in their wallet. This can only be called when the vault is unlocked.
   * @param _shares is the number of vault shares to be burned
   */
  function withdraw(uint256 _shares) external nonReentrant onlyUnlocked {
    uint256 withdrawAmount = _regularWithdraw(_shares);
    IERC20(asset).safeTransfer(msg.sender, withdrawAmount);
  }

  /**
   * @notice allow request to withdraw assets once current round ends.
   * @dev assets can only be withdrawn after this round ends and closePosition is called. This can only be called when the vault is locked.
   * This will burn the shares right now but the assets will be transferred back to the user only when `withdrawFromQueue` is called.
   * @param _shares the amount of shares the user wants to cash out
   */
  function registerWithdraw(uint256 _shares) external onlyLocked {
    _burn(msg.sender, _shares);
    userRoundQueuedWithdrawShares[msg.sender][round] = userRoundQueuedWithdrawShares[msg.sender][round].add(_shares);
    roundTotalQueuedWithdrawShares[round] = roundTotalQueuedWithdrawShares[round].add(_shares);
  }

  /**
   * @notice allow user to withdraw their promised assets from the withdraw queue anytime.
   * @dev Assets first need to be transferred to the withdraw queue.
   # This happens when the current round ends when closePositions is called.
   * @param _round the round the user registered a queue withdraw
   */
  function withdrawFromQueue(uint256 _round) external nonReentrant notEmergency {
    uint256 withdrawAmount = _withdrawFromQueue(_round);
    IERC20(asset).safeTransfer(msg.sender, withdrawAmount);
  }

  /**
   * @notice allow anyone close out the previous round by calling "closePositions" on all strategies.
   * @dev This will:
   * 1. call closePositions on all the strategies, withdrawing the money from all the strategies
   * 2. pay all the fees
   * 3. snapshot last round's shares and asset balances
   * 4. empty pendingDeposits and pull in those assets to be used in the next round
   * 5. set aside assets from the main vault into the withdrawQueue
   * 6. end the old round and unlocks the vault
   */
  function closePositions() public onlyLocked unlockState {
    // close positions on all the strategies and transfer assets back into the vault
    _closeAndWithdraw();

    _payRoundFee();

    // record the net shares and assets in current round and update pendingDeposits and withdrawQueue
    _snapshotShareAndAsset();

    round = round.add(1);
    currentRoundStartTimestamp = block.timestamp;
  }

  /**
   * @notice distribute funds to each strategy and lock the vault
   */
  function rollOver(uint256[] calldata _allocationPercentages) external virtual onlyOwner onlyUnlocked lockState {
    require(_allocationPercentages.length == strategies.length, "INVALID_INPUT");

    emit Rollover(_allocationPercentages);

    _distribute(_allocationPercentages);
  }

  /**
   * @notice set vault's state to "Emergency", which disables all withdrawals and deposits
   */
  function emergencyPause() external onlyOwner {
    stateBeforePause = state;
    state = VaultState.Emergency;
    emit StateUpdated(VaultState.Emergency);
  }

  /**
   * @notice set vault's state to whatever state it was before "Emergency"
   */
  function resumeFromPause() external onlyOwner {
    require(state == VaultState.Emergency, "!Emergency");
    state = stateBeforePause;
    emit StateUpdated(stateBeforePause);
  }

  /*=====================
   * Internal functions *
   *====================*/

  /**
   * @notice net assets controlled by this vault (effective balance + debts of strategies)
   */
  function _netAssetsControlled() internal view returns (uint256) {
    return _effectiveBalance().add(_totalDebt());
  }

  /**
   * @notice total assets controlled by the vault, including the pendingDeposits, withdrawQueue and debts of strategies
   */
  function _totalAssets() internal view returns (uint256) {
    return IERC20(asset).balanceOf(address(this)).add(_totalDebt());
  }

  /**
   * @notice return asset balance of the vault excluding assets registered to be withdrawn and assets in pendingDeposit.
   */
  function _effectiveBalance() internal view returns (uint256) {
    return IERC20(asset).balanceOf(address(this)).sub(pendingDeposit).sub(withdrawQueueAmount);
  }

  /**
   * @notice estimate amount of assets in all the strategies
   * this function iterates through all strategies and sum up the currentValue reported by each strategy.
   */
  function _totalDebt() internal view returns (uint256) {
    uint256 debt = 0;
    for (uint256 i = 0; i < strategies.length; i++) {
      debt = debt.add(YakStrategy(strategies[i]).estimateDeployedBalance());
    }
    return debt;
  }

  /**
   * @notice mint shares to depositor, and emit the deposit event
   */
  function _deposit(uint256 _amount) internal {
    // the asset is already deposited into the contract at this point, need to substract it from total
    uint256 netWithDepositedAmount = _netAssetsControlled();
    uint256 totalWithDepositedAmount = _totalAssets();
    require(totalWithDepositedAmount < cap, "Cap exceeded");
    uint256 netBeforeDeposit = netWithDepositedAmount.sub(_amount);

    uint256 share = _getSharesByDepositAmount(_amount, netBeforeDeposit);

    emit Deposit(msg.sender, _amount, share);
    emit Sync(netWithDepositedAmount, totalWithDepositedAmount);

    _mint(msg.sender, share);
  }

  /**
   * @notice iterate through each strategy, close position and withdraw funds
   */
  function _closeAndWithdraw() internal {
    for (uint8 i = 0; i < strategies.length; i = i + 1) {

      _closePositionAndUnlock(strategies[i]);
    }
  }

  /**
   * @notice distribute effective balance to different strategies
   * @dev vault manager can keep a reserve in the vault by not distributing all the funds.
   */
  function _distribute(uint256[] memory _percentages) internal nonReentrant {
    uint256 totalBalance = _effectiveBalance();

    currentRoundStartingAmount = totalBalance;

    // track total percentage and ensure summation is within 100%
    uint256 sumPercentage;
    for (uint8 i = 0; i < strategies.length; i = i + 1) {
      sumPercentage = sumPercentage.add(_percentages[i]);
      require(sumPercentage <= BASE, "PERCENTAGE_SUM_EXCEED_MAX");

      uint256 newAmount = totalBalance.mul(_percentages[i]).div(BASE);

      if (newAmount > 0) {
        IERC20(asset).safeTransfer(strategies[i], newAmount);
        _rollOverAndLock();
      }
    }

    require(sumPercentage == BASE, "PERCENTAGE_DOESNT_ADD_UP");
  }

  /**
   * @notice roll over vault position ahead of next round
   * @dev
   */
  function _rollOverAndLock() internal {
    require(block.timestamp - currentRoundStartTimestamp > minimumRuntime, "Cannot Rollover Vault");

    currentRoundStartTimestamp = block.timestamp;
  }

  function _closePositionAndUnlock(address strategy) internal {
    require(block.timestamp > minimumRuntime + 1 days, "Cannot Close Positions");

    uint256 strategyBalance = IERC20(asset).balanceOf(strategy);
    uint256 rewardsBalance = IERC20(WETH).balanceOf(address(this));

    YakStrategy(strategy).recoverERC20(asset, strategyBalance);
    YakStrategy(strategy).recoverAVAX((rewardsBalance * 995) / 1000);
  }

  /**
   * @notice calculate withdraw amount from queued shares, return withdraw amount to be handled by queueWithdraw or queueWithdrawETH
   * @param _round the round the user registered a queue withdraw
   */
  function _withdrawFromQueue(uint256 _round) internal returns (uint256) {
    require(_round < round, "Invalid round");

    uint256 queuedShares = userRoundQueuedWithdrawShares[msg.sender][_round];
    uint256 withdrawAmount = queuedShares.mul(roundTotalAsset[_round]).div(roundTotalShare[_round]);

    // remove user's queued shares
    userRoundQueuedWithdrawShares[msg.sender][_round] = 0;
    // decrease total asset we reserved for withdraw
    withdrawQueueAmount = withdrawQueueAmount.sub(withdrawAmount);

    emit WithdrawFromQueue(msg.sender, withdrawQueueAmount, _round);

    return withdrawAmount;
  }

  /**
   * @notice burn shares, return withdraw amount handle by withdraw or withdrawETH
   * @param _share amount of shares to burn for asset withdrawal.
   */
  function _regularWithdraw(uint256 _share) internal returns (uint256) {
    uint256 withdrawAmount = _getWithdrawAmountByShares(_share);

    _burn(msg.sender, _share);

    emit Withdraw(msg.sender, withdrawAmount, _share);

    return withdrawAmount;
  }

  /**
   * @notice return how many shares user can get if `_amount` asset is deposited
   * @param _amount amount of token depositing
   * @param _totalAssetAmount asset amount already in the pool before deposit
   */
  function _getSharesByDepositAmount(uint256 _amount, uint256 _totalAssetAmount) internal view returns (uint256) {
    uint256 shareSupply = totalSupply().add(roundTotalQueuedWithdrawShares[round]);

    uint256 shares = shareSupply == 0 ? _amount : _amount.mul(shareSupply).div(_totalAssetAmount);
    return shares;
  }

  /**
   * @notice return how many asset user can get if `_share` amount is burned
   */
  function _getWithdrawAmountByShares(uint256 _share) internal view returns (uint256) {
    uint256 effectiveShares = totalSupply();
    return _share.mul(_netAssetsControlled()).div(effectiveShares);
  }

  /**
   * @notice pay fee to fee recipient after pulling all assets back into vault
   */
  function _payRoundFee() internal {
    // don't need to call totalAsset() because strategies are empty now.
    uint256 newTotal = _effectiveBalance();
    uint256 profit;

    if (newTotal > currentRoundStartingAmount) profit = newTotal.sub(currentRoundStartingAmount);

    uint256 performanceFee = profit.mul(performanceFeeInPercent).div(BASE);

    uint256 managementFee =
      currentRoundStartingAmount
        .mul(managementFeeInPercent)
        .mul((block.timestamp.sub(currentRoundStartTimestamp)))
        .div(365 days)
        .div(BASE);
    uint256 totalFee = performanceFee.add(managementFee);
    if (totalFee > profit) totalFee = profit;

    currentRoundStartingAmount = 0;

    IERC20(asset).transfer(feeRecipient, totalFee);
  }

  /**
   * @notice snapshot last round's total shares and balance, excluding pending deposits.
   * @dev this function is called after withdrawing from strategy contracts and:
   * 1. snapshots last round's shares and asset balances
   * 2. empties pendingDeposits and pulls in those assets into the next round
   * 3. sets aside assets from the main vault into withdrawQueue
   */
  function _snapshotShareAndAsset() internal {
    uint256 vaultBalance = _effectiveBalance();
    uint256 outStandingShares = totalSupply();
    uint256 sharesBurned = roundTotalQueuedWithdrawShares[round];

    uint256 totalShares = outStandingShares.add(sharesBurned);

    // store this round's balance and shares
    roundTotalShare[round] = totalShares;
    roundTotalAsset[round] = vaultBalance;

    // === Handle withdraw queue === //
    uint256 roundReservedAsset = sharesBurned.mul(vaultBalance).div(totalShares);
    withdrawQueueAmount = withdrawQueueAmount.add(roundReservedAsset);

    // === Handle deposit queue === //
    uint256 sharesToMint = pendingDeposit.mul(totalShares).div(vaultBalance);
    _mint(address(this), sharesToMint);
    pendingDeposit = 0;
  }
}
