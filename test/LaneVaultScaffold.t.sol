// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LaneVaultScaffold } from "../src/LaneVaultScaffold.sol";

contract LaneVaultScaffoldTest {
  LaneVaultScaffold internal vault;

  function setUp() public {
    vault = new LaneVaultScaffold();
  }

  function testReserveEnforcesMaxUtilizationCap() public {
    vault.deposit(100_000);
    vault.reserveLiquidity(50_000);

    _assertEq(vault.freeLiquidityUsd(), 50_000, "free liquidity mismatch");
    _assertEq(vault.reservedLiquidityUsd(), 50_000, "reserved liquidity mismatch");
    _assertEq(vault.utilizationBps(), 5_000, "utilization mismatch");

    (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.reserveLiquidity.selector, 20_000));
    _assertTrue(!ok, "expected reserve above cap to revert");
  }

  function testSettlementSuccessAppliesFeeSplitsAndReserveCut() public {
    vault.deposit(100_000);
    vault.reserveLiquidity(10_000);
    vault.executeFill(10_000);
    vault.reconcileSettlementSuccess(10_000, 500);

    _assertEq(vault.inFlightLiquidityUsd(), 0, "in-flight should be zero");
    _assertEq(vault.freeLiquidityUsd(), 100_500, "free liquidity mismatch");
    _assertEq(vault.badDebtReserveUsd(), 50, "bad debt reserve mismatch");
    _assertEq(vault.protocolFeeAccruedUsd(), 0, "protocol fee should stay zero");
    _assertEq(vault.settledFeesEarnedUsd(), 450, "distributable fee mismatch");
  }

  function testSettlementLossDepletesReserveBeforeRealizedLoss() public {
    vault.deposit(100_000);
    vault.reserveLiquidity(10_000);
    vault.executeFill(10_000);

    // Build bad debt reserve on-chain before applying a loss path.
    vault.setPolicy(10_000, 6_000, 2_000, 0, 1_000);
    vault.reconcileSettlementSuccess(1_000, 600);

    vault.reconcileSettlementLoss(9_000, 8_000);

    _assertEq(vault.inFlightLiquidityUsd(), 0, "in-flight should be zero");
    _assertEq(vault.badDebtReserveUsd(), 0, "reserve should be depleted first");
    _assertEq(vault.realizedNavLossUsd(), 400, "realized loss mismatch");
    _assertEq(vault.freeLiquidityUsd(), 99_600, "free liquidity mismatch");
    _assertEq(vault.totalAssetsUsd(), 99_600, "total assets mismatch");
  }

  function testInvalidProtocolFeeConfigFailsSafeToFeeOff() public {
    vault.setPolicy(1_000, 6_000, 2_000, 2_000, 1_000);
    (
      uint16 badDebtReserveCutBps,
      uint16 maxUtilizationBps,
      uint16 targetHotReserveBps,
      uint16 protocolFeeBps,
      uint16 protocolFeeCapBps
    ) = vault.policy();

    _assertEq(badDebtReserveCutBps, 1_000, "bad debt bps mismatch");
    _assertEq(maxUtilizationBps, 6_000, "max utilization bps mismatch");
    _assertEq(targetHotReserveBps, 2_000, "target reserve bps mismatch");
    _assertEq(protocolFeeCapBps, 1_000, "protocol fee cap mismatch");
    _assertEq(protocolFeeBps, 0, "protocol fee bps must fail-safe to zero");

    vault.deposit(2_000);
    vault.reserveLiquidity(1_000);
    vault.executeFill(1_000);
    vault.reconcileSettlementSuccess(1_000, 100);
    _assertEq(vault.protocolFeeAccruedUsd(), 0, "protocol fees must remain zero");
  }

  function testInvalidTransitionsRevert() public {
    vault.deposit(10_000);
    vault.reserveLiquidity(1_000);

    (bool fillTooLarge,) = address(vault).call(abi.encodeWithSelector(vault.executeFill.selector, 2_000));
    _assertTrue(!fillTooLarge, "fill over reserved should revert");

    vault.executeFill(1_000);

    (bool recoveredExceedsPrincipal,) =
      address(vault).call(abi.encodeWithSelector(vault.reconcileSettlementLoss.selector, 1_000, 1_200));
    _assertTrue(!recoveredExceedsPrincipal, "recovered>principal should revert");

    (bool zeroReserve,) = address(vault).call(abi.encodeWithSelector(vault.reserveLiquidity.selector, 0));
    _assertTrue(!zeroReserve, "zero reserve must revert");
  }

  function _assertTrue(bool value, string memory message) internal pure {
    require(value, message);
  }

  function _assertEq(uint256 a, uint256 b, string memory message) internal pure {
    require(a == b, message);
  }
}
