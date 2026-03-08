// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title LaneVaultScaffold
/// @notice Phase-2 Solidity scaffold that mirrors the Python LP vault invariant model.
/// @dev Simulation-oriented contract; no token transfers or external integrations yet.
contract LaneVaultScaffold {
  error Unauthorized();
  error VaultInvariantViolation(string reason);

  uint16 internal constant BPS_DENOMINATOR = 10_000;

  address public immutable OWNER;

  struct Policy {
    uint16 badDebtReserveCutBps;
    uint16 maxUtilizationBps;
    uint16 targetHotReserveBps;
    uint16 protocolFeeBps;
    uint16 protocolFeeCapBps;
  }

  Policy public policy;

  uint256 public freeLiquidityUsd;
  uint256 public reservedLiquidityUsd;
  uint256 public inFlightLiquidityUsd;
  uint256 public badDebtReserveUsd;
  uint256 public protocolFeeAccruedUsd;
  uint256 public settledFeesEarnedUsd;
  uint256 public realizedNavLossUsd;

  event PolicyUpdated(
    uint16 badDebtReserveCutBps,
    uint16 maxUtilizationBps,
    uint16 targetHotReserveBps,
    uint16 protocolFeeBps,
    uint16 protocolFeeCapBps
  );
  event Deposited(uint256 amountUsd, uint256 freeLiquidityUsd);
  event LiquidityReserved(uint256 amountUsd, uint256 utilizationBps);
  event FillExecuted(uint256 amountUsd, uint256 inFlightLiquidityUsd);
  event SettlementReconciledSuccess(
    uint256 principalUsd,
    uint256 netFeeIncomeUsd,
    uint256 reserveCutUsd,
    uint256 protocolFeeUsd,
    uint256 distributableUsd
  );
  event SettlementReconciledLoss(
    uint256 principalUsd, uint256 recoveredUsd, uint256 reserveAbsorbUsd, uint256 uncoveredLossUsd
  );

  modifier onlyOwner() {
    if (msg.sender != OWNER) {
      revert Unauthorized();
    }
    _;
  }

  constructor() {
    OWNER = msg.sender;
    policy = _normalizePolicy(1000, 6000, 2000, 0, 1000);
  }

  function setPolicy(
    uint256 badDebtReserveCutBps,
    uint256 maxUtilizationBps,
    uint256 targetHotReserveBps,
    uint256 protocolFeeBps,
    uint256 protocolFeeCapBps
  ) external onlyOwner {
    policy = _normalizePolicy(
      badDebtReserveCutBps, maxUtilizationBps, targetHotReserveBps, protocolFeeBps, protocolFeeCapBps
    );
    emit PolicyUpdated(
      policy.badDebtReserveCutBps,
      policy.maxUtilizationBps,
      policy.targetHotReserveBps,
      policy.protocolFeeBps,
      policy.protocolFeeCapBps
    );
  }

  function totalAssetsUsd() public view returns (uint256) {
    return freeLiquidityUsd + reservedLiquidityUsd + inFlightLiquidityUsd;
  }

  function utilizationBps() public view returns (uint256) {
    uint256 total = totalAssetsUsd();
    if (total == 0) {
      return 0;
    }
    return ((reservedLiquidityUsd + inFlightLiquidityUsd) * BPS_DENOMINATOR) / total;
  }

  function deposit(uint256 amountUsd) external onlyOwner {
    if (amountUsd == 0) {
      revert VaultInvariantViolation("deposit amount must be positive");
    }
    freeLiquidityUsd += amountUsd;
    _assertReserveInvariant();
    emit Deposited(amountUsd, freeLiquidityUsd);
  }

  function reserveLiquidity(uint256 amountUsd) external onlyOwner {
    if (amountUsd == 0) {
      revert VaultInvariantViolation("reserve amount must be positive");
    }
    if (amountUsd > freeLiquidityUsd) {
      revert VaultInvariantViolation("insufficient free liquidity for reserve");
    }

    uint256 nextFree = freeLiquidityUsd - amountUsd;
    uint256 nextReserved = reservedLiquidityUsd + amountUsd;
    uint256 total = nextFree + nextReserved + inFlightLiquidityUsd;
    if (total > 0) {
      uint256 projectedUtil = ((nextReserved + inFlightLiquidityUsd) * BPS_DENOMINATOR) / total;
      if (projectedUtil > policy.maxUtilizationBps) {
        revert VaultInvariantViolation("max utilization exceeded");
      }
    }

    freeLiquidityUsd = nextFree;
    reservedLiquidityUsd = nextReserved;
    _assertReserveInvariant();
    emit LiquidityReserved(amountUsd, utilizationBps());
  }

  function executeFill(uint256 amountUsd) external onlyOwner {
    if (amountUsd == 0) {
      revert VaultInvariantViolation("fill amount must be positive");
    }
    if (amountUsd > reservedLiquidityUsd) {
      revert VaultInvariantViolation("fill exceeds reserved liquidity");
    }

    reservedLiquidityUsd -= amountUsd;
    inFlightLiquidityUsd += amountUsd;
    _assertReserveInvariant();
    emit FillExecuted(amountUsd, inFlightLiquidityUsd);
  }

  function reconcileSettlementSuccess(uint256 principalUsd, uint256 netFeeIncomeUsd) external onlyOwner {
    if (principalUsd == 0) {
      revert VaultInvariantViolation("principal must be positive");
    }
    if (principalUsd > inFlightLiquidityUsd) {
      revert VaultInvariantViolation("principal exceeds in-flight liquidity");
    }

    uint256 reserveCutUsd = (netFeeIncomeUsd * policy.badDebtReserveCutBps) / BPS_DENOMINATOR;
    uint256 protocolFeeUsd = (netFeeIncomeUsd * policy.protocolFeeBps) / BPS_DENOMINATOR;
    uint256 totalCuts = reserveCutUsd + protocolFeeUsd;
    uint256 distributableUsd = netFeeIncomeUsd > totalCuts ? netFeeIncomeUsd - totalCuts : 0;

    inFlightLiquidityUsd -= principalUsd;
    freeLiquidityUsd += principalUsd + netFeeIncomeUsd;
    badDebtReserveUsd += reserveCutUsd;
    protocolFeeAccruedUsd += protocolFeeUsd;
    settledFeesEarnedUsd += distributableUsd;

    _assertReserveInvariant();
    emit SettlementReconciledSuccess(principalUsd, netFeeIncomeUsd, reserveCutUsd, protocolFeeUsd, distributableUsd);
  }

  function reconcileSettlementLoss(uint256 principalUsd, uint256 recoveredUsd) external onlyOwner {
    if (principalUsd == 0) {
      revert VaultInvariantViolation("principal must be positive");
    }
    if (recoveredUsd > principalUsd) {
      revert VaultInvariantViolation("recovered amount cannot exceed principal");
    }
    if (principalUsd > inFlightLiquidityUsd) {
      revert VaultInvariantViolation("principal exceeds in-flight liquidity");
    }

    uint256 lossUsd = principalUsd - recoveredUsd;
    uint256 reserveAbsorbUsd = badDebtReserveUsd < lossUsd ? badDebtReserveUsd : lossUsd;
    uint256 uncoveredLossUsd = lossUsd - reserveAbsorbUsd;

    inFlightLiquidityUsd -= principalUsd;
    freeLiquidityUsd += recoveredUsd;
    badDebtReserveUsd -= reserveAbsorbUsd;
    realizedNavLossUsd += uncoveredLossUsd;

    _assertReserveInvariant();
    emit SettlementReconciledLoss(principalUsd, recoveredUsd, reserveAbsorbUsd, uncoveredLossUsd);
  }

  function _assertReserveInvariant() internal view {
    if (badDebtReserveUsd > freeLiquidityUsd) {
      revert VaultInvariantViolation("bad debt reserve cannot exceed free liquidity");
    }
  }

  function _normalizePolicy(
    uint256 badDebtReserveCutBps,
    uint256 maxUtilizationBps,
    uint256 targetHotReserveBps,
    uint256 protocolFeeBps,
    uint256 protocolFeeCapBps
  ) internal pure returns (Policy memory normalized) {
    uint16 cappedProtocolFeeCapBps = _clampBps(protocolFeeCapBps);
    uint16 cappedProtocolFeeBps = _clampBps(protocolFeeBps);

    // Fail-safe parity with Python model: invalid fee switch -> fee-off mode.
    if (cappedProtocolFeeBps > cappedProtocolFeeCapBps) {
      cappedProtocolFeeBps = 0;
    }

    normalized = Policy({
      badDebtReserveCutBps: _clampBps(badDebtReserveCutBps),
      maxUtilizationBps: _clampBps(maxUtilizationBps),
      targetHotReserveBps: _clampBps(targetHotReserveBps),
      protocolFeeBps: cappedProtocolFeeBps,
      protocolFeeCapBps: cappedProtocolFeeCapBps
    });
  }

  function _clampBps(uint256 value) internal pure returns (uint16) {
    if (value > BPS_DENOMINATOR) {
      return BPS_DENOMINATOR;
    }
    return uint16(value);
  }
}
