// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/badger/IController.sol";

import { BaseStrategy } from "../deps/BaseStrategy.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

contract MyStrategy is BaseStrategy {
  using SafeERC20Upgradeable for IERC20Upgradeable;
  using AddressUpgradeable for address;
  using SafeMathUpgradeable for uint256;

  // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
  address public lpComponent; // Token we provide liquidity with
  address public reward; // Token we farm and swap to want / lpComponent

  // constants
  address public constant want = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88; // Uniswap V3: Positions NFT
  address public constant pool = 0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35; // Uniswap V3: WBTC-USDC pool

  int24 public immutable tickSpacing;

  int24 public baseThreshold;
  int24 public limitThreshold;
  int24 public maxTwapDeviation;
  uint32 public twapDuration;

  uint256 public lastRebalance;
  int24 public lastTick;

  // Used to signal to the Badger Tree that rewards where sent to it
  event TreeDistribution(
    address indexed token,
    uint256 amount,
    uint256 indexed blockNumber,
    uint256 timestamp
  );

  function initialize(
    address _governance,
    address _strategist,
    address _controller,
    address _keeper,
    address _guardian,
    address[3] memory _wantConfig,
    uint256[3] memory _feeConfig
  ) public initializer {
    __BaseStrategy_init(
      _governance,
      _strategist,
      _controller,
      _keeper,
      _guardian
    );

    // uniswap v3 strategy config
    IUniswapV3Pool _pool = IUniswapV3Pool(pool);
    int24 _tickSpacing = _pool.tickSpacing();

    tickSpacing = _tickSpacing;

    baseThreshold = _baseThreshold;
    limitThreshold = _limitThreshold;
    maxTwapDeviation = _maxTwapDeviation;
    twapDuration = _twapDuration;
    keeper = _keeper;

    _checkThreshold(_baseThreshold, _tickSpacing);
    _checkThreshold(_limitThreshold, _tickSpacing);
    require(_maxTwapDeviation > 0, "maxTwapDeviation");
    require(_twapDuration > 0, "twapDuration");

    (, lastTick, , , , , ) = _pool.slot0();

    /// @dev Add config here
    want = _wantConfig[0];
    lpComponent = _wantConfig[1];
    reward = _wantConfig[2];

    performanceFeeGovernance = _feeConfig[0];
    performanceFeeStrategist = _feeConfig[1];
    withdrawalFee = _feeConfig[2];

    /// @dev do one off approvals here
    // IERC20Upgradeable(want).safeApprove(gauge, type(uint256).max);
  }

  /// ===== View Functions =====

  // @dev Specify the name of the strategy
  function getName() external pure override returns (string memory) {
    return "StrategyName";
  }

  // @dev Specify the version of the Strategy, for upgrades
  function version() external pure returns (string memory) {
    return "1.0";
  }

  /// @dev Balance of want currently held in strategy positions
  function balanceOfPool() public view override returns (uint256) {
    return 0;
  }

  /// @dev Returns true if this strategy requires tending
  function isTendable() public view override returns (bool) {
    return true;
  }

  // @dev These are the tokens that cannot be moved except by the vault
  function getProtectedTokens()
    public
    view
    override
    returns (address[] memory)
  {
    address[] memory protectedTokens = new address[](3);
    protectedTokens[0] = want;
    protectedTokens[1] = lpComponent;
    protectedTokens[2] = reward;
    return protectedTokens;
  }

  /// ===== Internal Core Implementations =====

  /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
  function _onlyNotProtectedTokens(address _asset) internal override {
    address[] memory protectedTokens = getProtectedTokens();

    for (uint256 x = 0; x < protectedTokens.length; x++) {
      require(address(protectedTokens[x]) != _asset, "Asset is protected");
    }
  }

  /// @dev invest the amount of want
  /// @notice When this function is called, the controller has already sent want to this
  /// @notice Just get the current balance and then invest accordingly
  function _deposit(uint256 _amount) internal override {}

  /// @dev utility function to withdraw everything for migration
  function _withdrawAll() internal override {}

  /// @dev withdraw the specified amount of want, liquidate from lpComponent to want, paying off any necessary debt for the conversion
  function _withdrawSome(uint256 _amount) internal override returns (uint256) {
    return _amount;
  }

  // rebalance pool position every n hours
  function rebalance() external whenNotPaused {
    _onlyAuthorizedActors();

    int24 _baseThreshold = baseThreshold;
    int24 _limitThreshold = limitThreshold;

    // Check price is not too close to min/max allowed by Uniswap. Price
    // shouldn't be this extreme unless something was wrong with the pool.
    int24 tick = getTick();
    int24 maxThreshold =
      _baseThreshold > _limitThreshold ? _baseThreshold : _limitThreshold;
    require(
      tick > TickMath.MIN_TICK + maxThreshold + tickSpacing,
      "tick too low"
    );
    require(
      tick < TickMath.MAX_TICK - maxThreshold - tickSpacing,
      "tick too high"
    );

    // Check price has not moved a lot recently. This mitigates price
    // manipulation during rebalance and also prevents placing orders
    // when it's too volatile.
    int24 twap = getTwap();
    int24 deviation = tick > twap ? tick - twap : twap - tick;
    require(deviation <= maxTwapDeviation, "maxTwapDeviation");

    int24 tickFloor = _floor(tick);
    int24 tickCeil = tickFloor + tickSpacing;

    vault.rebalance(
      0,
      0,
      tickFloor - _baseThreshold,
      tickCeil + _baseThreshold,
      tickFloor - _limitThreshold,
      tickFloor,
      tickCeil,
      tickCeil + _limitThreshold
    );

    lastRebalance = block.timestamp;
    lastTick = tick;
  }

  /// @dev Fetches current price in ticks from Uniswap pool.
  function getTick() public view returns (int24 tick) {
    (, tick, , , , , ) = pool.slot0();
  }

  // burn position and collect liquidity
  function _burnAndCollect(
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity
  )
    internal
    returns (
      uint256 burned0,
      uint256 burned1,
      uint256 feesToVault0,
      uint256 feesToVault1
    )
  {}

  /// @dev Harvest from strategy mechanics, realizing increase in underlying position
  function harvest() external whenNotPaused returns (uint256 harvested) {
    _onlyAuthorizedActors();

    uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

    // Write your code here
    // collect fees from pool

    uint256 earned =
      IERC20Upgradeable(want).balanceOf(address(this)).sub(_before);

    /// @notice Keep this in so you get paid!
    (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) =
      _processRewardsFees(earned, want);

    // TODO: If you are harvesting a reward token you're not compounding
    // You probably still want to capture fees for it
    // // Process Sushi rewards if existing
    // if (sushiAmount > 0) {
    //     // Process fees on Sushi Rewards
    //     // NOTE: Use this to receive fees on the reward token
    //     _processRewardsFees(sushiAmount, SUSHI_TOKEN);

    //     // Transfer balance of Sushi to the Badger Tree
    //     // NOTE: Send reward to badgerTree
    //     uint256 sushiBalance = IERC20Upgradeable(SUSHI_TOKEN).balanceOf(address(this));
    //     IERC20Upgradeable(SUSHI_TOKEN).safeTransfer(badgerTree, sushiBalance);
    //
    //     // NOTE: Signal the amount of reward sent to the badger tree
    //     emit TreeDistribution(SUSHI_TOKEN, sushiBalance, block.number, block.timestamp);
    // }

    /// @dev Harvest event that every strategy MUST have, see BaseStrategy
    emit Harvest(earned, block.number);

    /// @dev Harvest must return the amount of want increased
    return earned;
  }

  // Alternative Harvest with Price received from harvester, used to avoid exessive front-running
  function harvest(uint256 price)
    external
    whenNotPaused
    returns (uint256 harvested)
  {}

  /// @dev Rebalance, Compound or Pay off debt here
  function tend() external whenNotPaused {
    _onlyAuthorizedActors();
  }

  /// ===== Internal Helper Functions =====

  /// @dev used to manage the governance and strategist fee on earned rewards, make sure to use it to get paid!
  function _processRewardsFees(uint256 _amount, address _token)
    internal
    returns (uint256 governanceRewardsFee, uint256 strategistRewardsFee)
  {
    governanceRewardsFee = _processFee(
      _token,
      _amount,
      performanceFeeGovernance,
      IController(controller).rewards()
    );

    strategistRewardsFee = _processFee(
      _token,
      _amount,
      performanceFeeStrategist,
      strategist
    );
  }

  function _checkThreshold(int24 threshold, int24 _tickSpacing) internal pure {
    require(threshold > 0, "threshold > 0");
    require(threshold <= TickMath.MAX_TICK, "threshold too high");
    require(threshold % _tickSpacing == 0, "threshold % tickSpacing");
  }
}
