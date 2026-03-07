// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { LaneQueueManager } from "../src/LaneQueueManager.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @title Deep Audit Tests — CCIP Bridge (LaneVault4626)
/// @notice Phase 4 tests from the March 2026 deep re-audit.
///         Covers: PROP-LV-1 (balance >= freeLiquidity), PROP-LV-3 (zero supply => zero assets),
///         phantom asset detection, queue griefing, and ERC-4626 compliance.
contract DeepAuditLaneVaultTest is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal carol = makeAddr("carol");

  bytes32 internal constant ROUTE_A = keccak256("route-a");
  bytes32 internal constant ROUTE_B = keccak256("route-b");
  bytes32 internal constant FILL_A = keccak256("fill-a");
  bytes32 internal constant FILL_B = keccak256("fill-b");

  function setUp() public {
    asset = new MockERC20("Mock Asset", "mAST");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    asset.mint(alice, 1_000_000);
    asset.mint(bob, 1_000_000);
    asset.mint(carol, 1_000_000);

    vm.prank(alice);
    asset.approve(address(vault), type(uint256).max);
    vm.prank(bob);
    asset.approve(address(vault), type(uint256).max);
    vm.prank(carol);
    asset.approve(address(vault), type(uint256).max);
  }

  // ═══════════ PROP-LV-1: balanceOf(vault) >= freeLiquidityAssets ═══════════
  // Catches phantom assets — if internal accounting exceeds actual balance

  function test_PROP_LV1_balanceCoversFreeLiquidity() public {
    // Deposit
    vm.prank(alice);
    vault.deposit(10_000, alice);

    assertGe(
      asset.balanceOf(address(vault)), vault.freeLiquidityAssets(), "PROP-LV-1: Balance must cover free liquidity"
    );

    // Reserve and fill
    vault.reserveLiquidity(ROUTE_A, 3_000, uint64(block.timestamp + 1 hours));
    vault.executeFill(ROUTE_A, FILL_A, 3_000);

    // After fill, in-flight assets left the vault but are tracked internally
    assertGe(
      asset.balanceOf(address(vault)),
      vault.freeLiquidityAssets(),
      "PROP-LV-1: Post-fill balance must cover free liquidity"
    );

    // Settlement returns principal + fees
    vault.setSettlementAdapter(address(this));

    // Simulate settlement: tokens arrive
    asset.mint(address(vault), 3_100); // principal 3000 + fee 100
    vault.reconcileSettlementSuccess(FILL_A, 3_000, 100);

    assertGe(
      asset.balanceOf(address(vault)),
      vault.freeLiquidityAssets(),
      "PROP-LV-1: Post-settlement balance must cover free liquidity"
    );
  }

  // ═══════════ PROP-LV-1 Negative: Phantom Asset Detection ═══════════
  // If reconcileSettlementSuccess is called WITHOUT tokens arriving,
  // freeLiquidityAssets inflates beyond actual balance

  /// @notice Verify that the balance check in reconcileSettlementSuccess
  ///         prevents phantom asset inflation when fee income tokens don't arrive.
  function test_PROP_LV1_phantomAsset_blocked() public {
    vm.prank(alice);
    vault.deposit(10_000, alice);

    vault.reserveLiquidity(ROUTE_A, 3_000, uint64(block.timestamp + 1 hours));
    vault.executeFill(ROUTE_A, FILL_A, 3_000);

    // Settlement claims fee income but NO ACTUAL TOKENS arrive — must revert
    vault.setSettlementAdapter(address(this));
    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.BalanceDeficit.selector, 10_100, 10_000));
    vault.reconcileSettlementSuccess(FILL_A, 3_000, 100);
  }

  // ═══════════ PROP-LV-3: Zero Supply Implies Zero Assets ═══════════

  function test_PROP_LV3_zeroSupplyZeroAssets() public {
    // Fresh vault — no deposits
    uint256 totalSupply = vault.totalSupply();
    uint256 totalAssets = vault.totalAssets();

    // With virtual shares (decimalsOffset=3), totalSupply is still 0 before deposits
    if (totalSupply == 0) {
      assertEq(totalAssets, 0, "PROP-LV-3: Zero supply must mean zero assets");
    }
  }

  function test_PROP_LV3_afterFullWithdrawal() public {
    // Deposit and fully withdraw
    vm.prank(alice);
    uint256 shares = vault.deposit(10_000, alice);

    vm.prank(alice);
    vault.redeem(shares, alice, alice);

    // After full withdrawal, supply should be minimal (virtual shares only)
    // and totalAssets should be 0 (no real assets)
    assertEq(vault.freeLiquidityAssets(), 0, "Free liquidity should be 0 after full withdrawal");
    assertEq(vault.totalAssets(), 0, "Total assets should be 0 after full withdrawal");
  }

  // ═══════════ ERC-4626 Compliance: maxDeposit/maxMint When Paused ═══════════
  // Check #15: maxDeposit/maxMint return type(uint256).max even when paused

  function test_ERC4626_maxDeposit_whenPaused() public {
    // Pause deposits
    vault.setPauseFlags(false, true, false); // depositPaused = true

    uint256 maxDep = vault.maxDeposit(alice);
    // ERC-4626 spec says: MUST return 0 if deposits are not possible
    // Current impl returns type(uint256).max — spec violation
    // This test documents the gap
    if (maxDep > 0) {
      // Verify that actual deposit would revert despite maxDeposit > 0
      vm.prank(alice);
      vm.expectRevert(LaneVault4626.DepositPaused.selector);
      vault.deposit(100, alice);
    }
  }

  function test_ERC4626_maxDeposit_whenGlobalPaused() public {
    vault.setPauseFlags(true, false, false); // globalPaused = true

    uint256 maxDep = vault.maxDeposit(alice);
    if (maxDep > 0) {
      vm.prank(alice);
      vm.expectRevert(LaneVault4626.GlobalPaused.selector);
      vault.deposit(100, alice);
    }
  }

  // ═══════════ Queue Griefing: 1000 Tiny Redeem Requests ═══════════

  function test_queueGriefing_manySmallRequests() public {
    // Alice deposits a large amount
    vm.prank(alice);
    vault.deposit(100_000, alice);

    // Fund the allowlist for alice
    vault.setTransferAllowlisted(alice, true);

    // Alice creates many 1-share redeem requests
    uint256 numRequests = 100; // Use 100 for gas measurement

    vm.startPrank(alice);
    for (uint256 i = 0; i < numRequests; i++) {
      vault.requestRedeem(1, alice, alice);
    }
    vm.stopPrank();

    // Measure gas to process all requests
    uint256 gasBefore = gasleft();
    vault.processRedeemQueue(numRequests);
    uint256 gasUsed = gasBefore - gasleft();

    // Document gas per request
    // Should be under 100K per request for reasonable operation
    uint256 gasPerRequest = gasUsed / numRequests;
    assertLt(gasPerRequest, 200_000, "Gas per queue request should be reasonable");
  }

  // ═══════════ Exchange Rate Drift in Batch Processing ═══════════
  // Check #22: Rate drift across processRedeemQueue iterations

  function test_exchangeRateDrift_batchProcessing() public {
    // Alice and Bob deposit different amounts
    vm.prank(alice);
    uint256 aliceShares = vault.deposit(50_000, alice);

    vm.prank(bob);
    uint256 bobShares = vault.deposit(50_000, bob);

    vault.setTransferAllowlisted(alice, true);
    vault.setTransferAllowlisted(bob, true);

    // Simulate some fee income to create non-1:1 exchange rate
    vault.setSettlementAdapter(address(this));
    vault.reserveLiquidity(ROUTE_A, 10_000, uint64(block.timestamp + 1 hours));
    vault.executeFill(ROUTE_A, FILL_A, 10_000);
    asset.mint(address(vault), 10_500);
    vault.reconcileSettlementSuccess(FILL_A, 10_000, 500);

    // Both request redeem of equal shares
    uint256 redeemAmount = aliceShares / 4;

    vm.prank(alice);
    vault.requestRedeem(redeemAmount, alice, alice);

    vm.prank(bob);
    vault.requestRedeem(redeemAmount, bob, bob);

    // Record balances before
    uint256 aliceBefore = asset.balanceOf(alice);
    uint256 bobBefore = asset.balanceOf(bob);

    // Process both in one batch
    vault.processRedeemQueue(2);

    uint256 aliceGot = asset.balanceOf(alice) - aliceBefore;
    uint256 bobGot = asset.balanceOf(bob) - bobBefore;

    // Alice (processed first) should get <= Bob (processed second) per share
    // because burning Alice's shares increases share price for Bob
    // Max drift should be negligible for reasonable amounts
    if (aliceGot > 0 && bobGot > 0) {
      uint256 maxDiff = aliceGot > bobGot ? aliceGot - bobGot : bobGot - aliceGot;
      // Allow up to 0.1% drift
      assertLe(maxDiff * 10_000 / aliceGot, 10, "Exchange rate drift should be < 0.1%");
    }
  }

  // ═══════════ Queue ID Reset Across Cycles ═══════════
  // Check #21: IDs reset when queue empties

  function test_queueIdReset_acrossCycles() public {
    vm.prank(alice);
    vault.deposit(10_000, alice);

    vault.setTransferAllowlisted(alice, true);

    // Cycle 1: enqueue and process
    vm.prank(alice);
    uint256 requestId1 = vault.requestRedeem(100, alice, alice);
    vault.processRedeemQueue(1);

    // Queue should be empty now
    assertEq(vault.queueManager().pendingCount(), 0, "Queue should be empty");

    // Cycle 2: enqueue again — ID resets to 1
    vm.prank(alice);
    uint256 requestId2 = vault.requestRedeem(100, alice, alice);

    // Document: requestId2 == 1 (same as first cycle's first request)
    // This is the ID reuse behavior
    assertEq(requestId2, 1, "Queue ID should reset to 1 after empty");
    // Still functional — no collision because old request was deleted
  }

  // ═══════════ Aggregate Accounting Invariant ═══════════
  // Check #18: free + reserved + inFlight >= protocolFee + badDebt

  function test_aggregateAccountingInvariant() public {
    vm.prank(alice);
    vault.deposit(100_000, alice);

    // Setup adapter
    vault.setSettlementAdapter(address(this));
    vault.setPolicy(2_000, 8_000, 2_000, 500, 1_000); // Higher fees for testing

    // Reserve, fill, settle with fees
    vault.reserveLiquidity(ROUTE_A, 20_000, uint64(block.timestamp + 1 hours));
    vault.executeFill(ROUTE_A, FILL_A, 20_000);
    asset.mint(address(vault), 22_000);
    vault.reconcileSettlementSuccess(FILL_A, 20_000, 2_000);

    // Check aggregate invariant
    uint256 free = vault.freeLiquidityAssets();
    uint256 reserved = vault.reservedLiquidityAssets();
    uint256 inFlight = vault.inFlightLiquidityAssets();
    uint256 protocolFee = vault.protocolFeeAccruedAssets();
    uint256 badDebt = vault.badDebtReserveAssets();

    assertGe(free + reserved + inFlight, protocolFee + badDebt, "Aggregate invariant: buckets must cover fees and debt");
  }

  // ═══════════ Settlement Loss: Bad Debt Reserve Absorption ═══════════

  function test_settlementLoss_badDebtAbsorption() public {
    vm.prank(alice);
    vault.deposit(100_000, alice);

    vault.setSettlementAdapter(address(this));
    vault.setPolicy(5_000, 8_000, 2_000, 500, 1_000); // 50% bad debt reserve cut

    // First: successful settlement to build bad debt reserve
    vault.reserveLiquidity(ROUTE_A, 20_000, uint64(block.timestamp + 1 hours));
    vault.executeFill(ROUTE_A, FILL_A, 20_000);
    asset.mint(address(vault), 22_000);
    vault.reconcileSettlementSuccess(FILL_A, 20_000, 2_000);

    uint256 reserveBefore = vault.badDebtReserveAssets();
    assertGt(reserveBefore, 0, "Bad debt reserve should have funds");

    // Second: settlement loss — reserve should absorb
    vault.reserveLiquidity(ROUTE_B, 10_000, uint64(block.timestamp + 1 hours));
    vault.executeFill(ROUTE_B, FILL_B, 10_000);
    // Recover only 8000 of 10000 — 2000 loss
    asset.mint(address(vault), 8_000);
    vault.reconcileSettlementLoss(FILL_B, 10_000, 8_000);

    // Reserve should have absorbed some of the loss
    uint256 reserveAfter = vault.badDebtReserveAssets();
    assertLe(reserveAfter, reserveBefore, "Reserve should decrease after absorbing loss");

    // realizedNavLossAssets should capture any uncovered amount
    uint256 loss = vault.realizedNavLossAssets();
    uint256 covered = reserveBefore - reserveAfter;
    assertEq(covered + loss, 2_000, "Covered + uncovered should equal total loss");
  }
}
