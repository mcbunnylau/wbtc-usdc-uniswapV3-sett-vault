// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "../interfaces/badger/IController.sol";
import "../interfaces/erc20/IERC20Detailed.sol";
import "../deps/SettAccessControlDefended.sol";
import "../interfaces/yearn/BadgerGuestlistApi.sol";

import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/* 
    Source: https://github.com/iearn-finance/yearn-protocol/blob/develop/contracts/vaults/yVault.sol
    
    Changelog:

    V1.1
    * Strategist no longer has special function calling permissions
    * Version function added to contract
    * All write functions, with the exception of transfer, are pausable
    * Keeper or governance can pause
    * Only governance can unpause

    V1.2
    * Transfer functions are now pausable along with all other non-permissioned write functions
    * All permissioned write functions, with the exception of pause() & unpause(), are pausable as well

    V1.3
    * Add guest list functionality
    * All deposits can be optionally gated by external guestList approval logic on set guestList contract

    V1.4
    * Add depositFor() to deposit on the half of other users. That user will then be blockLocked.

    V1.4-UniswapV3
    * Modified deposit and withdraw functions to match paired deposits.
    * Added a new function to facilitate strategy function calls like rebalancing.
*/

contract SettV4UniswapV3 is
  ERC20Upgradeable,
  SettAccessControlDefended,
  PausableUpgradeable
{
  using SafeERC20Upgradeable for IERC20Upgradeable;
  using AddressUpgradeable for address;
  using SafeMathUpgradeable for uint256;

  IUniswapV3Pool public immutable pool; // pool of Uniswap V3 tokens pair

  IERC20Upgradeable public token0; // token0 of paired token
  IERC20Upgradeable public token1; // token1 of paired token

  // position range for
  int24 public baseLower;
  int24 public baseUpper;
  int24 public limitLower;
  int24 public limitUpper;

  uint256 public min;
  uint256 public constant max = 10000;

  address public controller;

  mapping(address => uint256) public blockLock;

  string internal constant _defaultNamePrefix = "Badger Sett ";
  string internal constant _symbolSymbolPrefix = "b";

  address public guardian;

  BadgerGuestListAPI public guestList;

  event FullPricePerShareUpdated(
    uint256 value,
    uint256 indexed timestamp,
    uint256 indexed blockNumber
  );

  function initialize(
    address _pool,
    address _controller,
    address _governance,
    address _keeper,
    address _guardian,
    bool _overrideTokenName,
    string memory _namePrefix,
    string memory _symbolPrefix
  ) public initializer whenNotPaused {
    IERC20Detailed namedToken = IERC20Detailed(_token);
    string memory tokenName = namedToken.name();
    string memory tokenSymbol = namedToken.symbol();

    string memory name;
    string memory symbol;

    if (_overrideTokenName) {
      name = string(abi.encodePacked(_namePrefix, tokenName));
      symbol = string(abi.encodePacked(_symbolPrefix, tokenSymbol));
    } else {
      name = string(abi.encodePacked(_defaultNamePrefix, tokenName));
      symbol = string(abi.encodePacked(_symbolSymbolPrefix, tokenSymbol));
    }

    __ERC20_init(name, symbol);

    pool = IUniswapV3Pool(_pool);
    token0 = IERC20Upgradeable(IUniswapV3Pool(_pool).token0());
    token1 = IERC20Upgradeable(IUniswapV3Pool(_pool).token1());
    governance = _governance;
    strategist = address(0);
    keeper = _keeper;
    controller = _controller;
    guardian = _guardian;

    min = 9500;

    emit FullPricePerShareUpdated(getPricePerFullShare(), now, block.number);

    // Paused on launch
    _pause();
  }

  /// ===== Modifiers =====

  function _onlyController() internal view {
    require(msg.sender == controller, "onlyController");
  }

  function _onlyAuthorizedPausers() internal view {
    require(msg.sender == guardian || msg.sender == governance, "onlyPausers");
  }

  function _blockLocked() internal view {
    require(blockLock[msg.sender] < block.number, "blockLocked");
  }

  /// ===== View Functions =====

  function version() public view returns (string memory) {
    return "1.4-UniswapV3";
  }

  // prices for the pair per full share e.g. WBTC and USDC
  function getPricePerFullShare()
    public
    view
    virtual
    returns (uint256 _amount0, uint256 _amount1)
  {
    if (totalSupply() == 0) {
      return 1e18;
    }
    _amount0 = balance(address(token0)).mul(1e18).div(totalSupply());
    _amount1 = balance(address(token1)).mul(1e18).div(totalSupply());
  }

  /// @notice Return the total balance of the underlying token within the system
  /// @notice Sums the balance in the Sett, the Controller, and the Strategy
  /// @notice Return the balance based on the address specified in the input variables
  function balance(address _token) public view virtual returns (uint256) {
    IERC20Upgradeable __token = IERC20Upgradeable(_token);
    return
      __token.balanceOf(address(this)).add(
        IController(controller).balanceOf(address(__token))
      );
  }

  /// @notice Defines how much of the Setts' underlying can be borrowed by the Strategy for use
  /// @notice Custom logic in here for how much the vault allows to be borrowed
  /// @notice Sets minimum required on-hand to keep small withdrawals cheap
  function available()
    public
    view
    virtual
    returns (uint256 _amount0, uint256 _amount1)
  {
    _amount0 = token0.balanceOf(address(this)).mul(min).div(max);
    _amount1 = token1.balanceOf(address(this)).mul(min).div(max);
  }

  /// @notice Calculates the vault's total holdings of token0 and token1 - in
  // other words, how much of each token the vault would hold if it withdrew
  // all its liquidity from Uniswap.
  function getTotalAmounts()
    public
    view
    override
    returns (uint256 total0, uint256 total1)
  {
    (uint256 baseAmount0, uint256 baseAmount1) =
      getPositionAmounts(baseLower, baseUpper);
    (uint256 limitAmount0, uint256 limitAmount1) =
      getPositionAmounts(limitLower, limitUpper);
    total0 = getBalance0().add(baseAmount0).add(limitAmount0);
    total1 = getBalance1().add(baseAmount1).add(limitAmount1);
  }

  /// @notice Amounts of token0 and token1 held in vault's position
  function getPositionAmounts(int24 tickLower, int24 tickUpper)
    public
    view
    returns (uint256 amount0, uint256 amount1)
  {
    // get amount of liquidity owned by this position, get fees (in tokens) owed to position for token0 and token1 respectively
    (uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) =
      _position(tickLower, tickUpper);
    (amount0, amount1) = _amountsForLiquidity(tickLower, tickUpper, liquidity);

    // add fees owed to amount
    amount0 = amount0.add(uint256(tokensOwed0));
    amount1 = amount1.add(uint256(tokensOwed1));
  }

  /// @notice Balance of token0 in vault not used in any strategy
  function getBalance0() public view returns (uint256) {
    return token0.balanceOf(address(this));
  }

  /// @notice Balance of token1 in vault not used in any strategy
  function getBalance1() public view returns (uint256) {
    return token1.balanceOf(address(this));
  }

  /// ===== Public Actions =====

  /// @notice Deposit assets into the Sett, and return corresponding shares to the user
  /// @notice Only callable by EOA accounts that pass the _defend() check
  function deposit(
    uint256 _amount0Desired,
    uint256 _amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min
  ) public whenNotPaused {
    _defend();
    _blockLocked();

    _lockForBlock(msg.sender);
    _depositWithAuthorization(
      _amount0Desired,
      _amount1Desired,
      new bytes32[](0)
    );
  }

  /// @notice Deposit variant with proof for merkle guest list
  function deposit(
    uint256 _amount0Desired,
    uint256 _amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    bytes32[] memory proof
  ) public whenNotPaused {
    _defend();
    _blockLocked();

    _lockForBlock(msg.sender);
    _depositWithAuthorization(_amount0Desired, _amount1Desired, proof);
  }

  /// @notice Convenience function: Deposit entire balance of asset into the Sett, and return corresponding shares to the user
  /// @notice Only callable by EOA accounts that pass the _defend() check
  function depositAll() external whenNotPaused {
    _defend();
    _blockLocked();

    _lockForBlock(msg.sender);
    _depositWithAuthorization(
      token0.balanceOf(msg.sender),
      token1.balanceOf(msg.sender),
      new bytes32[](0)
    );
  }

  /// @notice DepositAll variant with proof for merkle guest list
  function depositAll(bytes32[] memory proof) external whenNotPaused {
    _defend();
    _blockLocked();

    _lockForBlock(msg.sender);
    _depositWithAuthorization(
      token0.balanceOf(msg.sender),
      token1.balanceOf(msg.sender),
      proof
    );
  }

  /// @notice Deposit assets into the Sett, and return corresponding shares to the user
  /// @notice Only callable by EOA accounts that pass the _defend() check
  function depositFor(
    address _recipient,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) public whenNotPaused {
    _defend();
    _blockLocked();

    _lockForBlock(_recipient);
    _depositForWithAuthorization(
      _recipient,
      _amount0Desired,
      _amount1Desired,
      new bytes32[](0)
    );
  }

  /// @notice Deposit variant with proof for merkle guest list
  function depositFor(
    address _recipient,
    uint256 _amount0Desired,
    uint256 _amount1Desired,
    bytes32[] memory proof
  ) public whenNotPaused {
    _defend();
    _blockLocked();

    _lockForBlock(_recipient);
    _depositForWithAuthorization(
      _recipient,
      _amount0Desired,
      _amount1Desired,
      proof
    );
  }

  /// @notice No rebalance implementation for lower fees and faster swaps
  function withdraw(uint256 _shares) public whenNotPaused {
    _defend();
    _blockLocked();

    _lockForBlock(msg.sender);
    _withdraw(_shares);
  }

  /// @notice Convenience function: Withdraw all shares of the sender
  function withdrawAll() external whenNotPaused {
    _defend();
    _blockLocked();

    _lockForBlock(msg.sender);
    _withdraw(balanceOf(msg.sender));
  }

  /// ===== Permissioned Actions: Governance =====

  function setGuestList(address _guestList) external whenNotPaused {
    _onlyGovernance();
    guestList = BadgerGuestListAPI(_guestList);
  }

  /// @notice Set minimum threshold of underlying that must be deposited in strategy
  /// @notice Can only be changed by governance
  function setMin(uint256 _min) external whenNotPaused {
    _onlyGovernance();
    min = _min;
  }

  /// @notice Change controller address
  /// @notice Can only be changed by governance
  function setController(address _controller) public whenNotPaused {
    _onlyGovernance();
    controller = _controller;
  }

  /// @notice Change guardian address
  /// @notice Can only be changed by governance
  function setGuardian(address _guardian) external whenNotPaused {
    _onlyGovernance();
    guardian = _guardian;
  }

  /// ===== Permissioned Actions: Controller =====

  /// @notice Used to swap any borrowed reserve over the debt limit to liquidate to 'token'
  /// @notice Only controller can trigger harvests
  function harvest(address reserve, uint256 amount) external whenNotPaused {
    _onlyController();
    require(reserve != address(token), "token");
    IERC20Upgradeable(reserve).safeTransfer(controller, amount);
  }

  /// ===== Permissioned Functions: Trusted Actors =====

  /// @notice Transfer the underlying available to be claimed to the controller
  /// @notice The controller will deposit into the Strategy for yield-generating activities
  /// @notice Permissionless operation
  function earn() public whenNotPaused {
    _onlyAuthorizedActors();

    uint256 _bal = available();
    token.safeTransfer(controller, _bal);
    IController(controller).earn(address(token), _bal);
  }

  /// @dev Emit event tracking current full price per share
  /// @dev Provides a pure on-chain way of approximating APY
  function trackFullPricePerShare() external whenNotPaused {
    _onlyAuthorizedActors();
    emit FullPricePerShareUpdated(getPricePerFullShare(), now, block.number);
  }

  function pause() external {
    _onlyAuthorizedPausers();
    _pause();
  }

  function unpause() external {
    _onlyGovernance();
    _unpause();
  }

  /// ===== Internal Implementations =====

  /// @dev Calculate the number of shares to issue for a given deposit
  /// @dev This is based on the realized value of underlying assets between Sett & associated Strategy
  // @dev deposit for msg.sender
  function _deposit(uint256 _amount0Desired, uint256 _amount1Desired) internal {
    _depositFor(msg.sender, _amount0Desired, _amount1Desired);
  }

  function _depositFor(
    address recipient,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) internal virtual {
    // // for additional checks
    // uint256 _before0 = token0.balanceOf(address(this)); // balance of token0 of vault before transfer
    // uint256 _before1 = token1.balanceOf(address(this)); // balance of token1 of vault before transfer

    (uint256 shares, uint256 amount0, uint256 amount1) =
      _calcSharesAndAmounts(_amount0Desired, _amount1Desired);

    // pull in tokens from sender
    if (amount0 > 0) {
      token0.safeTransferFrom(msg.sender, address(this), amount0);
    }
    if (amount0 > 0) {
      token1.safeTransferFrom(msg.sender, address(this), amount1);
    }

    // uint256 _after0 = token0.balanceOf(address(this)); // balance of token0 of vault after transfer
    // uint256 _after1 = token1.balanceOf(address(this)); // balance of token1 of vault after transfer

    /// @notice not entirely sure how to implement this check so left out for the time being
    // _amount0 = _after.sub(_before); // Additional check for deflationary tokens
    // _amount1 = _after.sub(_before); // Additional check for deflationary tokens

    _mint(recipient, shares);
  }

  function _calcSharesAndAmounts(uint256 amount0Desired, uint256 amount1Desired)
    internal
    view
    returns (
      uint256 shares,
      uint256 amount0,
      uint256 amount1
    )
  {
    uint256 totalSupply = totalSupply(); // total supply of shares
    (uint256 total0, uint256 total1) = getTotalAmounts();

    // If total supply > 0, vault can't be empty
    assert(totalSupply == 0 || total0 > 0 || total1 > 0);

    if (totalSupply == 0) {
      // For first deposit, just use the amounts desired
      amount0 = amount0Desired;
      amount1 = amount1Desired;
      shares = Math.max(amount0, amount1);
    } else if (total0 == 0) {
      amount1 = amount1Desired;
      shares = amount1.mul(totalSupply).div(total1);
    } else if (total1 == 0) {
      amount0 = amount0Desired;
      shares = amount0.mul(totalSupply).div(total0);
    } else {
      uint256 cross =
        Math.min(amount0Desired.mul(total1), amount1Desired.mul(total0));
      require(cross > 0, "cross");

      // Round up amounts
      amount0 = cross.sub(1).div(total1).add(1);
      amount1 = cross.sub(1).div(total0).add(1);
      shares = cross.mul(totalSupply).div(total0).div(total1);
    }
  }

  /// @dev Wrapper around `IUniswapV3Pool.positions()`.
  function _position(int24 tickLower, int24 tickUpper)
    internal
    view
    returns (
      uint128,
      uint256,
      uint256,
      uint128,
      uint128
    )
  {
    bytes32 positionKey =
      PositionKey.compute(address(this), tickLower, tickUpper);
    return pool.positions(positionKey);
  }

  /// @dev Wrapper around `LiquidityAmounts.getAmountsForLiquidity()`.
  function _amountsForLiquidity(
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity
  ) internal view returns (uint256, uint256) {
    (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
    return
      LiquidityAmounts.getAmountsForLiquidity(
        sqrtRatioX96,
        TickMath.getSqrtRatioAtTick(tickLower),
        TickMath.getSqrtRatioAtTick(tickUpper),
        liquidity
      );
  }

  function _depositWithAuthorization(
    uint256 _amount0Desired,
    uint256 _amount1Desired,
    bytes32[] memory proof
  ) internal virtual {
    if (address(guestList) != address(0)) {
      require(
        guestList.authorized(msg.sender, _amount0, proof),
        "guest-list-authorization"
      );
      require(
        guestList.authorized(msg.sender, _amount1, proof),
        "guest-list-authorization"
      );
    }
    _deposit(_amount0Desired, _amount1Desired);
  }

  function _depositForWithAuthorization(
    address _recipient,
    uint256 _amount,
    bytes32[] memory proof
  ) internal virtual {
    if (address(guestList) != address(0)) {
      require(
        guestList.authorized(_recipient, _amount, proof),
        "guest-list-authorization"
      );
    }
    _depositFor(_recipient, _amount);
  }

  // No rebalance implementation for lower fees and faster swaps
  function _withdraw(uint256 _shares) internal virtual {
    uint256 r = (balance().mul(_shares)).div(totalSupply());
    _burn(msg.sender, _shares);

    // Check balance
    uint256 b = token.balanceOf(address(this));
    if (b < r) {
      uint256 _toWithdraw = r.sub(b);
      IController(controller).withdraw(address(token), _toWithdraw);
      uint256 _after = token.balanceOf(address(this));
      uint256 _diff = _after.sub(b);
      if (_diff < _toWithdraw) {
        r = b.add(_diff);
      }
    }

    token.safeTransfer(msg.sender, r);
  }

  function _lockForBlock(address account) internal {
    blockLock[account] = block.number;
  }

  /// ===== ERC20 Overrides =====

  /// @dev Add blockLock to transfers, users cannot transfer tokens in the same block as a deposit or withdrawal.
  function transfer(address recipient, uint256 amount)
    public
    virtual
    override
    whenNotPaused
    returns (bool)
  {
    _blockLocked();
    return super.transfer(recipient, amount);
  }

  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) public virtual override whenNotPaused returns (bool) {
    _blockLocked();
    return super.transferFrom(sender, recipient, amount);
  }
}
