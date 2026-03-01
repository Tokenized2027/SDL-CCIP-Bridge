// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC4626 } from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {
  AccessControlDefaultAdminRules
} from "openzeppelin-contracts/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { LaneQueueManager } from "./LaneQueueManager.sol";

/// @title LaneVault4626
/// @notice ERC-4626 vault with strict FIFO redemption queue and bridge liquidity accounting.
/// @dev Accounting is asset-unit native. Protocol fees are excluded from LP NAV immediately in totalAssets().
contract LaneVault4626 is ERC4626, AccessControlDefaultAdminRules, ReentrancyGuard {
  using SafeERC20 for IERC20;

  error GlobalPaused();
  error DepositPaused();
  error ReservePaused();
  error InvalidAmount();
  error InvalidIdentifier();
  error InvalidTransition();
  error InsufficientFreeLiquidity();
  error UtilizationCapExceeded();
  error InvariantViolation(string reason);
  error TransferNotAllowlisted(address from, address to);
  error ReservationNotExpired(bytes32 routeId, uint64 expiry);
  error BalanceDeficit(uint256 expected, uint256 actual);

  bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
  bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
  bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

  uint16 public constant BPS_DENOMINATOR = 10_000;

  enum RouteStatus {
    None,
    Reserved,
    Released,
    Filled,
    SettledSuccess,
    SettledLoss
  }

  enum FillStatus {
    None,
    Executed,
    SettledSuccess,
    SettledLoss
  }

  struct RouteReservation {
    RouteStatus status;
    uint256 amount;
    uint64 expiry;
    bytes32 fillId;
  }

  struct FillPosition {
    FillStatus status;
    bytes32 routeId;
    uint256 amount;
    uint64 executedAt;
  }

  struct PreviewOutcome {
    uint256 instantAssets;
    uint256 queuedAssets;
  }

  // Policy values
  uint16 public badDebtReserveCutBps = 1000;
  uint16 public maxUtilizationBps = 6000;
  uint16 public targetHotReserveBps = 2000;
  uint16 public protocolFeeBps = 0;
  uint16 public protocolFeeCapBps = 1000;

  // Pause flags
  bool public globalPaused;
  bool public depositPaused;
  bool public reservePaused;

  // Launch transfer controls
  bool public transferAllowlistEnabled = true;
  mapping(address => bool) public isTransferAllowlisted;

  // Liquidity buckets (asset units)
  uint256 public freeLiquidityAssets;
  uint256 public reservedLiquidityAssets;
  uint256 public inFlightLiquidityAssets;
  uint256 public badDebtReserveAssets;
  uint256 public protocolFeeAccruedAssets;
  uint256 public settledFeesEarnedAssets;
  uint256 public realizedNavLossAssets;

  // Bridge lifecycle state machines
  mapping(bytes32 => RouteReservation) public routes;
  mapping(bytes32 => FillPosition) public fills;

  LaneQueueManager public immutable queueManager;
  address public settlementAdapter;

  event PolicyUpdated(
    uint16 badDebtReserveCutBps,
    uint16 maxUtilizationBps,
    uint16 targetHotReserveBps,
    uint16 protocolFeeBps,
    uint16 protocolFeeCapBps
  );
  event PauseFlagsUpdated(bool globalPaused, bool depositPaused, bool reservePaused);
  event TransferAllowlistModeUpdated(bool enabled);
  event TransferAllowlisted(address indexed account, bool allowed);
  event SettlementAdapterUpdated(address indexed previousAdapter, address indexed newAdapter);

  event LiquidityReserved(bytes32 indexed routeId, uint256 amount, uint64 expiry);
  event ReservationReleased(bytes32 indexed routeId, uint256 amount);
  event FillExecuted(bytes32 indexed fillId, bytes32 indexed routeId, uint256 amount);
  event SettlementSuccess(bytes32 indexed fillId, bytes32 indexed routeId, uint256 principal, uint256 netFeeIncome);
  event SettlementLoss(bytes32 indexed fillId, bytes32 indexed routeId, uint256 principal, uint256 recovered);

  error EmergencyReleaseNotReady(bytes32 fillId, uint256 readyAt);

  uint48 public emergencyReleaseDelay = 3 days;

  event EmergencyReleaseDelayUpdated(uint48 newDelay);
  event EmergencyFillReleased(bytes32 indexed fillId, bytes32 indexed routeId, uint256 principal, uint256 recovered);
  event ReservationExpired(bytes32 indexed routeId, uint256 amount);
  event RedeemQueued(uint256 indexed requestId, address indexed owner, address indexed receiver, uint256 shares);
  event RedeemQueueProcessed(uint256 indexed requestId, address indexed receiver, uint256 shares, uint256 assetsPaid);
  event ProtocolFeesClaimed(address indexed to, uint256 amount);

  constructor(IERC20 asset_, string memory name_, string memory symbol_, uint48 defaultAdminDelay, address initialAdmin)
    ERC20(name_, symbol_)
    ERC4626(asset_)
    AccessControlDefaultAdminRules(defaultAdminDelay, initialAdmin)
  {
    queueManager = new LaneQueueManager(address(this));

    _grantRole(GOVERNANCE_ROLE, initialAdmin);
    _grantRole(OPS_ROLE, initialAdmin);
    _grantRole(PAUSER_ROLE, initialAdmin);

    isTransferAllowlisted[initialAdmin] = true;
    isTransferAllowlisted[address(this)] = true;
    isTransferAllowlisted[address(queueManager)] = true;
  }

  /// @notice Virtual decimals offset to prevent ERC-4626 inflation attacks.
  /// @dev This creates a 1e3 virtual offset in share/asset conversion, making first-depositor
  ///      share price manipulation economically unviable.
  function _decimalsOffset() internal pure override returns (uint8) {
    return 3;
  }

  /// @notice LP NAV excludes protocol-accrued fees immediately.
  function totalAssets() public view override returns (uint256) {
    uint256 grossAssets = freeLiquidityAssets + reservedLiquidityAssets + inFlightLiquidityAssets;
    if (protocolFeeAccruedAssets >= grossAssets) {
      return 0;
    }
    return grossAssets - protocolFeeAccruedAssets;
  }

  /// @notice ERC-4626 compliance: return 0 when deposits are not possible.
  function maxDeposit(address) public view override returns (uint256) {
    if (globalPaused || depositPaused) return 0;
    return type(uint256).max;
  }

  /// @notice ERC-4626 compliance: return 0 when minting is not possible.
  function maxMint(address) public view override returns (uint256) {
    if (globalPaused || depositPaused) return 0;
    return type(uint256).max;
  }

  function maxWithdraw(address owner) public view override returns (uint256) {
    uint256 ownerAssets = previewRedeem(balanceOf(owner));
    uint256 available = availableFreeLiquidityForLP();
    return ownerAssets < available ? ownerAssets : available;
  }

  function maxRedeem(address owner) public view override returns (uint256) {
    uint256 maxAssets = maxWithdraw(owner);
    if (maxAssets == 0) return 0;
    uint256 equivalentShares = convertToShares(maxAssets);
    uint256 ownerShares = balanceOf(owner);
    return equivalentShares < ownerShares ? equivalentShares : ownerShares;
  }

  function availableFreeLiquidityForLP() public view returns (uint256) {
    if (freeLiquidityAssets <= protocolFeeAccruedAssets) {
      return 0;
    }
    return freeLiquidityAssets - protocolFeeAccruedAssets;
  }

  function previewRedeemOutcome(uint256 shares) external view returns (PreviewOutcome memory outcome) {
    uint256 assets = previewRedeem(shares);
    uint256 available = availableFreeLiquidityForLP();
    outcome.instantAssets = assets < available ? assets : available;
    outcome.queuedAssets = assets > outcome.instantAssets ? assets - outcome.instantAssets : 0;
  }

  function previewWithdrawOutcome(uint256 assets) external view returns (PreviewOutcome memory outcome) {
    uint256 available = availableFreeLiquidityForLP();
    outcome.instantAssets = assets < available ? assets : available;
    outcome.queuedAssets = assets > outcome.instantAssets ? assets - outcome.instantAssets : 0;
  }

  /// @notice Queue cancellation policy for v1 launch.
  /// @dev Requests are non-cancelable once enqueued.
  function queueCancellationPolicy() external pure returns (string memory) {
    return "no_cancel_once_enqueued";
  }

  function setPolicy(
    uint256 badDebtReserveCutBps_,
    uint256 maxUtilizationBps_,
    uint256 targetHotReserveBps_,
    uint256 protocolFeeBps_,
    uint256 protocolFeeCapBps_
  ) external onlyRole(GOVERNANCE_ROLE) {
    badDebtReserveCutBps = _clampBps(badDebtReserveCutBps_);
    maxUtilizationBps = _clampBps(maxUtilizationBps_);
    targetHotReserveBps = _clampBps(targetHotReserveBps_);
    protocolFeeCapBps = _clampBps(protocolFeeCapBps_);

    uint16 requestedProtocolFeeBps = _clampBps(protocolFeeBps_);
    protocolFeeBps = requestedProtocolFeeBps > protocolFeeCapBps ? 0 : requestedProtocolFeeBps;

    emit PolicyUpdated(badDebtReserveCutBps, maxUtilizationBps, targetHotReserveBps, protocolFeeBps, protocolFeeCapBps);
  }

  function setPauseFlags(bool globalPaused_, bool depositPaused_, bool reservePaused_) external onlyRole(PAUSER_ROLE) {
    globalPaused = globalPaused_;
    depositPaused = depositPaused_;
    reservePaused = reservePaused_;
    emit PauseFlagsUpdated(globalPaused_, depositPaused_, reservePaused_);
  }

  function setTransferAllowlistEnabled(bool enabled) external onlyRole(GOVERNANCE_ROLE) {
    transferAllowlistEnabled = enabled;
    emit TransferAllowlistModeUpdated(enabled);
  }

  function setTransferAllowlisted(address account, bool allowed) external onlyRole(GOVERNANCE_ROLE) {
    isTransferAllowlisted[account] = allowed;
    emit TransferAllowlisted(account, allowed);
  }

  function setSettlementAdapter(address newAdapter) external onlyRole(GOVERNANCE_ROLE) {
    address previous = settlementAdapter;
    if (previous != address(0)) {
      _revokeRole(SETTLEMENT_ROLE, previous);
    }

    settlementAdapter = newAdapter;
    if (newAdapter != address(0)) {
      _grantRole(SETTLEMENT_ROLE, newAdapter);
    }
    emit SettlementAdapterUpdated(previous, newAdapter);
  }

  function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
    _requireNotGlobalPaused();
    if (depositPaused) revert DepositPaused();

    shares = super.deposit(assets, receiver);
    freeLiquidityAssets += assets;
    _assertAccountingInvariants();
  }

  function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
    _requireNotGlobalPaused();
    if (depositPaused) revert DepositPaused();

    assets = super.mint(shares, receiver);
    freeLiquidityAssets += assets;
    _assertAccountingInvariants();
  }

  function withdraw(uint256 assets, address receiver, address owner)
    public
    override
    nonReentrant
    returns (uint256 shares)
  {
    _requireNotGlobalPaused();
    if (assets > availableFreeLiquidityForLP()) revert InsufficientFreeLiquidity();

    shares = super.withdraw(assets, receiver, owner);
    freeLiquidityAssets -= assets;
    _assertAccountingInvariants();
  }

  function redeem(uint256 shares, address receiver, address owner)
    public
    override
    nonReentrant
    returns (uint256 assets)
  {
    _requireNotGlobalPaused();
    assets = previewRedeem(shares);
    if (assets > availableFreeLiquidityForLP()) revert InsufficientFreeLiquidity();

    assets = super.redeem(shares, receiver, owner);
    freeLiquidityAssets -= assets;
    _assertAccountingInvariants();
  }

  function requestRedeem(uint256 shares, address receiver, address owner)
    external
    nonReentrant
    returns (uint256 requestId)
  {
    _requireNotGlobalPaused();
    if (shares == 0 || receiver == address(0) || owner == address(0)) revert InvalidAmount();

    if (owner != _msgSender()) {
      _spendAllowance(owner, _msgSender(), shares);
    }

    // Escrow shares in the vault (policy: no cancel once enqueued).
    _transfer(owner, address(this), shares);

    requestId = queueManager.enqueue(owner, receiver, shares);
    emit RedeemQueued(requestId, owner, receiver, shares);
  }

  function processRedeemQueue(uint256 maxRequests)
    external
    nonReentrant
    onlyRole(OPS_ROLE)
    returns (uint256 processed)
  {
    _requireNotGlobalPaused();
    if (maxRequests == 0) revert InvalidAmount();

    for (uint256 i = 0; i < maxRequests; i++) {
      (bool exists, LaneQueueManager.RedeemRequest memory request) = queueManager.peek();
      if (!exists) break;

      uint256 assetsDue = previewRedeem(request.shares);
      if (assetsDue > availableFreeLiquidityForLP()) break;

      LaneQueueManager.RedeemRequest memory dequeued = queueManager.dequeue();

      _burn(address(this), dequeued.shares);
      freeLiquidityAssets -= assetsDue;
      IERC20(asset()).safeTransfer(dequeued.receiver, assetsDue);

      processed += 1;
      emit RedeemQueueProcessed(dequeued.requestId, dequeued.receiver, dequeued.shares, assetsDue);
    }

    _assertAccountingInvariants();
  }

  function reserveLiquidity(bytes32 routeId, uint256 amount, uint64 expiry) external nonReentrant onlyRole(OPS_ROLE) {
    _requireNotGlobalPaused();
    if (reservePaused) revert ReservePaused();
    if (routeId == bytes32(0) || amount == 0) revert InvalidIdentifier();
    if (amount > availableFreeLiquidityForLP()) revert InsufficientFreeLiquidity();

    RouteReservation storage route = routes[routeId];
    if (route.status != RouteStatus.None) revert InvalidTransition();

    uint256 projectedReserved = reservedLiquidityAssets + amount;
    uint256 lpManaged = totalAssets();
    if (lpManaged == 0) revert InvariantViolation("lp_managed_assets_zero");
    uint256 projectedUtilizationBps = ((projectedReserved + inFlightLiquidityAssets) * BPS_DENOMINATOR) / lpManaged;
    if (projectedUtilizationBps > maxUtilizationBps) revert UtilizationCapExceeded();

    freeLiquidityAssets -= amount;
    reservedLiquidityAssets += amount;
    route.status = RouteStatus.Reserved;
    route.amount = amount;
    route.expiry = expiry;

    _assertAccountingInvariants();
    emit LiquidityReserved(routeId, amount, expiry);
  }

  function releaseReservation(bytes32 routeId) external nonReentrant onlyRole(OPS_ROLE) {
    _requireNotGlobalPaused();
    if (reservePaused) revert ReservePaused();
    if (routeId == bytes32(0)) revert InvalidIdentifier();

    RouteReservation storage route = routes[routeId];
    if (route.status != RouteStatus.Reserved) revert InvalidTransition();

    uint256 amount = route.amount;
    reservedLiquidityAssets -= amount;
    freeLiquidityAssets += amount;

    route.status = RouteStatus.Released;
    route.amount = 0;
    route.fillId = bytes32(0);

    _assertAccountingInvariants();
    emit ReservationReleased(routeId, amount);
  }

  /// @notice Permissionlessly release a reservation whose expiry has passed.
  /// @dev Anyone can call this to free liquidity blocked by stale reservations.
  function expireReservation(bytes32 routeId) external nonReentrant {
    if (routeId == bytes32(0)) revert InvalidIdentifier();

    RouteReservation storage route = routes[routeId];
    if (route.status != RouteStatus.Reserved) revert InvalidTransition();
    if (block.timestamp < route.expiry) revert ReservationNotExpired(routeId, route.expiry);

    uint256 amount = route.amount;
    reservedLiquidityAssets -= amount;
    freeLiquidityAssets += amount;

    route.status = RouteStatus.Released;
    route.amount = 0;
    route.fillId = bytes32(0);

    _assertAccountingInvariants();
    emit ReservationExpired(routeId, amount);
  }

  function executeFill(bytes32 routeId, bytes32 fillId, uint256 amount) external nonReentrant onlyRole(OPS_ROLE) {
    _requireNotGlobalPaused();
    if (reservePaused) revert ReservePaused();
    if (routeId == bytes32(0) || fillId == bytes32(0) || amount == 0) revert InvalidIdentifier();

    RouteReservation storage route = routes[routeId];
    if (route.status != RouteStatus.Reserved) revert InvalidTransition();
    if (route.amount != amount) revert InvalidAmount();

    FillPosition storage fill = fills[fillId];
    if (fill.status != FillStatus.None) revert InvalidTransition();

    reservedLiquidityAssets -= amount;
    inFlightLiquidityAssets += amount;

    route.status = RouteStatus.Filled;
    route.fillId = fillId;
    fill.status = FillStatus.Executed;
    fill.routeId = routeId;
    fill.amount = amount;
    fill.executedAt = uint64(block.timestamp);

    _assertAccountingInvariants();
    emit FillExecuted(fillId, routeId, amount);
  }

  function reconcileSettlementSuccess(bytes32 fillId, uint256 principalAssets, uint256 netFeeIncomeAssets)
    external
    nonReentrant
    onlyRole(SETTLEMENT_ROLE)
  {
    _requireNotGlobalPaused();
    if (fillId == bytes32(0) || principalAssets == 0) revert InvalidIdentifier();

    FillPosition storage fill = fills[fillId];
    if (fill.status != FillStatus.Executed || fill.amount != principalAssets) revert InvalidTransition();

    RouteReservation storage route = routes[fill.routeId];
    if (route.status != RouteStatus.Filled || route.fillId != fillId) revert InvalidTransition();

    // Verify tokens actually arrived before crediting internal accounting
    uint256 expectedBalance = freeLiquidityAssets + principalAssets + netFeeIncomeAssets
      + reservedLiquidityAssets + protocolFeeAccruedAssets + badDebtReserveAssets;
    uint256 actualBalance = IERC20(asset()).balanceOf(address(this));
    if (actualBalance < expectedBalance) revert BalanceDeficit(expectedBalance, actualBalance);

    uint256 reserveCut = (netFeeIncomeAssets * badDebtReserveCutBps) / BPS_DENOMINATOR;
    uint256 protocolFee = (netFeeIncomeAssets * protocolFeeBps) / BPS_DENOMINATOR;
    uint256 distributable =
      netFeeIncomeAssets > reserveCut + protocolFee ? netFeeIncomeAssets - reserveCut - protocolFee : 0;

    inFlightLiquidityAssets -= principalAssets;
    freeLiquidityAssets += principalAssets + netFeeIncomeAssets;
    badDebtReserveAssets += reserveCut;
    protocolFeeAccruedAssets += protocolFee;
    settledFeesEarnedAssets += distributable;

    fill.status = FillStatus.SettledSuccess;
    route.status = RouteStatus.SettledSuccess;

    _assertAccountingInvariants();
    emit SettlementSuccess(fillId, fill.routeId, principalAssets, netFeeIncomeAssets);
  }

  function reconcileSettlementLoss(bytes32 fillId, uint256 principalAssets, uint256 recoveredAssets)
    external
    nonReentrant
    onlyRole(SETTLEMENT_ROLE)
  {
    _requireNotGlobalPaused();
    if (fillId == bytes32(0) || principalAssets == 0) revert InvalidIdentifier();
    if (recoveredAssets > principalAssets) revert InvalidAmount();

    FillPosition storage fill = fills[fillId];
    if (fill.status != FillStatus.Executed || fill.amount != principalAssets) revert InvalidTransition();

    RouteReservation storage route = routes[fill.routeId];
    if (route.status != RouteStatus.Filled || route.fillId != fillId) revert InvalidTransition();

    uint256 loss = principalAssets - recoveredAssets;
    uint256 reserveAbsorb = badDebtReserveAssets < loss ? badDebtReserveAssets : loss;
    uint256 uncovered = loss - reserveAbsorb;

    inFlightLiquidityAssets -= principalAssets;
    freeLiquidityAssets += recoveredAssets;
    badDebtReserveAssets -= reserveAbsorb;
    realizedNavLossAssets += uncovered;

    fill.status = FillStatus.SettledLoss;
    route.status = RouteStatus.SettledLoss;

    _assertAccountingInvariants();
    emit SettlementLoss(fillId, fill.routeId, principalAssets, recoveredAssets);
  }

  function claimProtocolFees(address to, uint256 amount) external nonReentrant onlyRole(GOVERNANCE_ROLE) {
    _requireNotGlobalPaused();
    if (to == address(0) || amount == 0) revert InvalidAmount();
    if (amount > protocolFeeAccruedAssets || amount > freeLiquidityAssets) revert InvalidAmount();

    protocolFeeAccruedAssets -= amount;
    freeLiquidityAssets -= amount;
    IERC20(asset()).safeTransfer(to, amount);

    _assertAccountingInvariants();
    emit ProtocolFeesClaimed(to, amount);
  }

  /// @notice Emergency release a fill stuck in Executed state after the delay has elapsed.
  /// @dev Marks the fill as a loss, absorbs via bad debt reserve. Use when CCIP settlement is stuck.
  /// @param fillId The fill to release
  /// @param recoveredAssets Actual tokens recovered (0 if total loss, or partial if manually rescued)
  function emergencyReleaseFill(bytes32 fillId, uint256 recoveredAssets)
    external
    nonReentrant
    onlyRole(GOVERNANCE_ROLE)
  {
    if (fillId == bytes32(0)) revert InvalidIdentifier();

    FillPosition storage fill = fills[fillId];
    if (fill.status != FillStatus.Executed) revert InvalidTransition();
    if (recoveredAssets > fill.amount) revert InvalidAmount();

    uint64 readyAt = fill.executedAt + emergencyReleaseDelay;
    if (block.timestamp < readyAt) revert EmergencyReleaseNotReady(fillId, readyAt);

    RouteReservation storage route = routes[fill.routeId];

    uint256 principal = fill.amount;
    uint256 loss = principal - recoveredAssets;
    uint256 reserveAbsorb = badDebtReserveAssets < loss ? badDebtReserveAssets : loss;
    uint256 uncovered = loss - reserveAbsorb;

    inFlightLiquidityAssets -= principal;
    freeLiquidityAssets += recoveredAssets;
    badDebtReserveAssets -= reserveAbsorb;
    realizedNavLossAssets += uncovered;

    fill.status = FillStatus.SettledLoss;
    route.status = RouteStatus.SettledLoss;

    _assertAccountingInvariants();
    emit EmergencyFillReleased(fillId, fill.routeId, principal, recoveredAssets);
  }

  function setEmergencyReleaseDelay(uint48 newDelay) external onlyRole(GOVERNANCE_ROLE) {
    require(newDelay >= 1 days, "Minimum 1 day delay");
    emergencyReleaseDelay = newDelay;
    emit EmergencyReleaseDelayUpdated(newDelay);
  }

  function _update(address from, address to, uint256 value) internal override {
    if (transferAllowlistEnabled && !_isTransferExempt(from, to)) {
      if (!isTransferAllowlisted[from] || !isTransferAllowlisted[to]) {
        revert TransferNotAllowlisted(from, to);
      }
    }
    super._update(from, to, value);
  }

  function _isTransferExempt(address from, address to) internal view returns (bool) {
    if (from == address(0) || to == address(0)) return true; // mint / burn
    if (from == address(this) || to == address(this)) return true; // escrow enqueue/dequeue and vault-internal
    if (from == address(queueManager) || to == address(queueManager)) return true; // queue helper movements
    return false;
  }

  function _requireNotGlobalPaused() internal view {
    if (globalPaused) revert GlobalPaused();
  }

  function _assertAccountingInvariants() internal view {
    if (badDebtReserveAssets > freeLiquidityAssets) {
      revert InvariantViolation("bad_debt_reserve_exceeds_free_liquidity");
    }
    if (protocolFeeAccruedAssets > freeLiquidityAssets) {
      revert InvariantViolation("protocol_fee_exceeds_free_liquidity");
    }
  }

  function _clampBps(uint256 value) internal pure returns (uint16) {
    if (value > BPS_DENOMINATOR) return BPS_DENOMINATOR;
    return uint16(value);
  }
}
