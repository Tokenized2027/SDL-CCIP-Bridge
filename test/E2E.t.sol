// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { LaneQueueManager } from "../src/LaneQueueManager.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @title End-to-End Lifecycle Tests
/// @notice Full lifecycle scenarios tracing deposit through final withdrawal.
///         Each test exercises the complete vault state machine across all 6 phases:
///         Deposit > Reserve > Fill > Settle > Redeem/Queue > Process.
///         Verifies accounting invariants at every step, not just the final state.
///
/// @dev Key vault design detail: availableFreeLiquidityForLP() = free - protocolFees - badDebtReserve.
///      LPs can only redeem up to maxRedeem(), which respects this constraint.
///      Protocol fees must be claimed by governance, and bad debt reserve is insurance.
///      After all LPs exit, only badDebtReserve + unclaimed protocolFees remain in the vault.
contract E2ELifecycleTest is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal alice = makeAddr("alice"); // LP #1
  address internal bob = makeAddr("bob"); // LP #2
  address internal carol = makeAddr("carol"); // LP #3
  address internal governance = makeAddr("governance");
  address internal feeReceiver = makeAddr("feeReceiver");

  function setUp() public {
    asset = new MockERC20("LINK", "LINK");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    _mintAndApprove(alice, 100_000_000e18);
    _mintAndApprove(bob, 100_000_000e18);
    _mintAndApprove(carol, 100_000_000e18);

    vault.setSettlementAdapter(address(this));
    vault.grantRole(vault.GOVERNANCE_ROLE(), governance);

    // Policy: 10% bad debt cut, 80% max util, 20% hot reserve, 5% protocol fee, 10% fee cap
    vm.prank(governance);
    vault.setPolicy(1_000, 8_000, 2_000, 500, 1_000);

    vault.setTransferAllowlisted(alice, true);
    vault.setTransferAllowlisted(bob, true);
    vault.setTransferAllowlisted(carol, true);
  }

  function _mintAndApprove(address who, uint256 amount) internal {
    asset.mint(who, amount);
    vm.prank(who);
    asset.approve(address(vault), type(uint256).max);
  }

  /// @dev Simulate fee income arriving at the vault (CCIP settlement brings tokens)
  function _simulateFeeIncome(uint256 amount) internal {
    asset.mint(address(vault), amount);
  }

  /// @dev Assert 5-bucket accounting: all accounted tokens backed by real balance
  function _assertBuckets() internal {
    uint256 grossBuckets =
      vault.freeLiquidityAssets() + vault.reservedLiquidityAssets() + vault.inFlightLiquidityAssets();
    uint256 heldBalance = asset.balanceOf(address(vault));
    assertLe(grossBuckets, heldBalance, "Bucket sum exceeds held balance");
  }

  /// @dev Governance claims all protocol fees, then LP redeems via maxRedeem
  function _claimFeesAndRedeem(address lp) internal returns (uint256 assetsOut) {
    // Claim protocol fees first to maximize available liquidity
    uint256 fees = vault.protocolFeeAccruedAssets();
    if (fees > 0) {
      vm.prank(governance);
      vault.claimProtocolFees(feeReceiver, fees);
    }
    // Redeem max available shares
    uint256 redeemable = vault.maxRedeem(lp);
    if (redeemable > 0) {
      vm.prank(lp);
      assetsOut = vault.redeem(redeemable, lp, lp);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // E2E-01: Happy Path: deposit > reserve > fill > success settle > redeem
  // ═══════════════════════════════════════════════════════════════════
  /// @notice The simplest full lifecycle. LP deposits, bridge cycle completes
  ///         with fee income, LP redeems with profit.
  function test_E2E01_HappyPath_FullCycle() public {
    // ── Step 1: Alice deposits 1M ──
    vm.prank(alice);
    uint256 shares = vault.deposit(1_000_000e18, alice);
    assertGt(shares, 0, "E2E01: shares minted");
    assertEq(vault.freeLiquidityAssets(), 1_000_000e18, "E2E01: free = 1M after deposit");
    assertEq(vault.totalAssets(), 1_000_000e18, "E2E01: totalAssets = 1M");
    _assertBuckets();

    // ── Step 2: Reserve 500k for a bridge route ──
    bytes32 routeId = keccak256("route-happy-01");
    uint64 expiry = uint64(block.timestamp + 1 hours);
    vault.reserveLiquidity(routeId, 500_000e18, expiry);
    assertEq(vault.freeLiquidityAssets(), 500_000e18, "E2E01: free = 500k after reserve");
    assertEq(vault.reservedLiquidityAssets(), 500_000e18, "E2E01: reserved = 500k");
    _assertBuckets();

    // ── Step 3: Execute fill ──
    bytes32 fillId = keccak256("fill-happy-01");
    vault.executeFill(routeId, fillId, 500_000e18);
    assertEq(vault.reservedLiquidityAssets(), 0, "E2E01: reserved = 0 after fill");
    assertEq(vault.inFlightLiquidityAssets(), 500_000e18, "E2E01: inFlight = 500k");
    _assertBuckets();

    // ── Step 4: Settlement success with 5k fee income ──
    uint256 feeIncome = 5_000e18;
    _simulateFeeIncome(feeIncome);
    vault.reconcileSettlementSuccess(fillId, 500_000e18, feeIncome);
    assertEq(vault.inFlightLiquidityAssets(), 0, "E2E01: inFlight = 0 after settle");

    // Fee split: 10% bad debt cut = 500, 5% protocol fee = 250, distributable = 4250
    assertEq(vault.badDebtReserveAssets(), 500e18, "E2E01: badDebt reserve = 500");
    assertEq(vault.protocolFeeAccruedAssets(), 250e18, "E2E01: protocol fee = 250");
    assertEq(vault.settledFeesEarnedAssets(), 4_250e18, "E2E01: distributable = 4250");
    assertEq(vault.freeLiquidityAssets(), 1_005_000e18, "E2E01: free = 1,005,000");
    // totalAssets = free - protocolFees = 1,005,000 - 250 = 1,004,750
    assertEq(vault.totalAssets(), 1_004_750e18, "E2E01: totalAssets includes fee income minus protocol");
    _assertBuckets();

    // ── Step 5: Governance claims protocol fees, then Alice redeems ──
    uint256 aliceAssetsBefore = asset.balanceOf(alice);
    uint256 aliceOut = _claimFeesAndRedeem(alice);
    assertGt(aliceOut, 1_000_000e18, "E2E01: LP received more than deposited (fee income)");

    uint256 aliceProfit = asset.balanceOf(alice) - aliceAssetsBefore;
    assertEq(aliceProfit, aliceOut, "E2E01: profit equals assets received");
    // Bad debt reserve stays in vault (insurance)
    assertEq(vault.badDebtReserveAssets(), 500e18, "E2E01: badDebt reserve untouched");
    _assertBuckets();
  }

  // ═══════════════════════════════════════════════════════════════════
  // E2E-02: Queue Path: LP redeems when liquidity is locked in-flight
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Two LPs deposit, most liquidity reserved. Second LP queues redeem.
  ///         After settlement, queue is processed, then first LP redeems.
  function test_E2E02_QueuedRedemption_FullCycle() public {
    // ── Step 1: Two LPs deposit ──
    vm.prank(alice);
    vault.deposit(600_000e18, alice);
    vm.prank(bob);
    vault.deposit(400_000e18, bob);
    assertEq(vault.totalAssets(), 1_000_000e18);
    _assertBuckets();

    // ── Step 2: Reserve 700k (70% utilization, under 80% cap) ──
    bytes32 routeId = keccak256("route-queue-01");
    vault.reserveLiquidity(routeId, 700_000e18, uint64(block.timestamp + 2 hours));

    // ── Step 3: Fill ──
    bytes32 fillId = keccak256("fill-queue-01");
    vault.executeFill(routeId, fillId, 700_000e18);

    assertEq(vault.freeLiquidityAssets(), 300_000e18);
    assertEq(vault.inFlightLiquidityAssets(), 700_000e18);

    // ── Step 4: Bob tries to redeem all. maxRedeem < balanceOf, so queue. ──
    uint256 bobShares = vault.balanceOf(bob);
    uint256 bobMaxRedeem = vault.maxRedeem(bob);
    assertLt(bobMaxRedeem, bobShares, "E2E02: Bob can't instant-redeem all");

    vm.prank(bob);
    uint256 requestId = vault.requestRedeem(bobShares, bob, bob);
    assertGt(requestId, 0, "E2E02: request ID assigned");
    assertEq(vault.balanceOf(bob), 0, "E2E02: shares escrowed in vault");
    assertEq(vault.queueManager().pendingCount(), 1);
    _assertBuckets();

    // ── Step 5: Settlement arrives (principal + 3k fees) ──
    uint256 feeIncome = 3_000e18;
    _simulateFeeIncome(feeIncome);
    vault.reconcileSettlementSuccess(fillId, 700_000e18, feeIncome);
    assertEq(vault.freeLiquidityAssets(), 1_003_000e18);
    _assertBuckets();

    // ── Step 6: Process queue ──
    uint256 bobBalanceBefore = asset.balanceOf(bob);
    uint256 processed = vault.processRedeemQueue(10);
    assertEq(processed, 1, "E2E02: 1 request processed");
    assertEq(vault.queueManager().pendingCount(), 0, "E2E02: queue empty");

    uint256 bobReceived = asset.balanceOf(bob) - bobBalanceBefore;
    assertGt(bobReceived, 0, "E2E02: Bob received assets from queue");
    _assertBuckets();

    // ── Step 7: Claim fees, then Alice redeems ──
    uint256 aliceOut = _claimFeesAndRedeem(alice);
    assertGt(aliceOut, 0, "E2E02: Alice redeemed");
    _assertBuckets();
  }

  // ═══════════════════════════════════════════════════════════════════
  // E2E-03: Multi-Route Mixed Settlement: 3 routes, 2 succeed, 1 loss
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Concurrent bridge operations with mixed outcomes.
  ///         Validates blended NAV after success+loss combo.
  function test_E2E03_MultiRoute_MixedSettlement() public {
    // Raise util cap for this test
    vm.prank(governance);
    vault.setPolicy(1_000, 9_500, 2_000, 500, 1_000);

    // ── Step 1: Three LPs deposit ──
    vm.prank(alice);
    vault.deposit(500_000e18, alice);
    vm.prank(bob);
    vault.deposit(300_000e18, bob);
    vm.prank(carol);
    vault.deposit(200_000e18, carol);
    assertEq(vault.totalAssets(), 1_000_000e18);

    // ── Step 2: Three concurrent reserves (total 800k) ──
    bytes32 r1 = keccak256("route-multi-01");
    bytes32 r2 = keccak256("route-multi-02");
    bytes32 r3 = keccak256("route-multi-03");
    uint64 exp = uint64(block.timestamp + 4 hours);

    vault.reserveLiquidity(r1, 400_000e18, exp);
    vault.reserveLiquidity(r2, 250_000e18, exp);
    vault.reserveLiquidity(r3, 150_000e18, exp);
    assertEq(vault.reservedLiquidityAssets(), 800_000e18);
    _assertBuckets();

    // ── Step 3: All three fills ──
    bytes32 f1 = keccak256("fill-multi-01");
    bytes32 f2 = keccak256("fill-multi-02");
    bytes32 f3 = keccak256("fill-multi-03");
    vault.executeFill(r1, f1, 400_000e18);
    vault.executeFill(r2, f2, 250_000e18);
    vault.executeFill(r3, f3, 150_000e18);
    assertEq(vault.inFlightLiquidityAssets(), 800_000e18);
    _assertBuckets();

    // ── Step 4a: Route 1 SUCCESS with 4k fees ──
    _simulateFeeIncome(4_000e18);
    vault.reconcileSettlementSuccess(f1, 400_000e18, 4_000e18);
    _assertBuckets();

    // ── Step 4b: Route 2 SUCCESS with 2.5k fees ──
    _simulateFeeIncome(2_500e18);
    vault.reconcileSettlementSuccess(f2, 250_000e18, 2_500e18);
    _assertBuckets();

    // ── Step 4c: Route 3 LOSS: only 100k recovered of 150k ──
    vault.reconcileSettlementLoss(f3, 150_000e18, 100_000e18);
    _assertBuckets();

    // badDebtReserve after success: (4000*10%) + (2500*10%) = 400 + 250 = 650
    // Loss = 50k. Reserve absorbs 650, uncovered = 49,350
    assertEq(vault.badDebtReserveAssets(), 0, "E2E03: reserve fully consumed by loss");
    assertEq(vault.realizedNavLossAssets(), 49_350e18, "E2E03: uncovered loss = 49,350");

    // ── Step 5: totalAssets < 1M due to net loss ──
    uint256 ta = vault.totalAssets();
    assertLt(ta, 1_000_000e18, "E2E03: totalAssets < initial due to loss");

    // ── Step 6: Claim fees, then all LPs redeem ──
    uint256 fees = vault.protocolFeeAccruedAssets();
    vm.prank(governance);
    vault.claimProtocolFees(feeReceiver, fees);

    uint256 aliceMax = vault.maxRedeem(alice);
    vm.prank(alice);
    uint256 aliceOut = vault.redeem(aliceMax, alice, alice);
    uint256 bobMax = vault.maxRedeem(bob);
    vm.prank(bob);
    uint256 bobOut = vault.redeem(bobMax, bob, bob);
    uint256 carolMax = vault.maxRedeem(carol);
    vm.prank(carol);
    uint256 carolOut = vault.redeem(carolMax, carol, carol);

    // Total redeemed < total deposited (net loss)
    assertLt(aliceOut + bobOut + carolOut, 1_000_000e18, "E2E03: LPs absorbed net loss");
    // Proportional: alice (50%) gets ~50% of remaining
    uint256 totalOut = aliceOut + bobOut + carolOut;
    uint256 alicePercent = (aliceOut * 100) / totalOut;
    assertEq(alicePercent, 50, "E2E03: alice gets proportional 50%");
    _assertBuckets();
  }

  // ═══════════════════════════════════════════════════════════════════
  // E2E-04: Emergency Release: fill stuck 3+ days, governance releases
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Fill stuck (CCIP never settles). After 3 days, governance does
  ///         emergency release with partial recovery. LP redeems at loss.
  function test_E2E04_EmergencyRelease_FullCycle() public {
    // ── Step 1: Deposit ──
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    // ── Step 2: Reserve + Fill ──
    bytes32 routeId = keccak256("route-emergency-01");
    bytes32 fillId = keccak256("fill-emergency-01");
    vault.reserveLiquidity(routeId, 300_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, 300_000e18);
    uint256 totalBefore = vault.totalAssets();
    _assertBuckets();

    // ── Step 3: 3 days pass ──
    vm.warp(block.timestamp + 3 days + 1);

    // ── Step 4: Emergency release with 200k recovered (100k loss) ──
    vm.prank(governance);
    vault.emergencyReleaseFill(fillId, 200_000e18);
    assertEq(vault.inFlightLiquidityAssets(), 0, "E2E04: inFlight cleared");
    assertLt(vault.totalAssets(), totalBefore, "E2E04: totalAssets decreased by loss");
    _assertBuckets();

    // ── Step 5: Alice redeems at reduced NAV ──
    uint256 aliceMax = vault.maxRedeem(alice);
    vm.prank(alice);
    uint256 assetsOut = vault.redeem(aliceMax, alice, alice);
    assertLt(assetsOut, 1_000_000e18, "E2E04: Alice absorbed emergency loss");
    assertGt(assetsOut, 800_000e18, "E2E04: not a catastrophic loss");
    _assertBuckets();
  }

  // ═══════════════════════════════════════════════════════════════════
  // E2E-05: Fee Claim + Queue Interaction
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Governance claims protocol fees between settlement and queue processing.
  ///         Ensures fee claim doesn't break queue processing.
  function test_E2E05_FeeClaimThenQueueProcess() public {
    // ── Step 1: Deposit ──
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    // ── Step 2: Reserve + Fill ──
    bytes32 routeId = keccak256("route-fee-01");
    bytes32 fillId = keccak256("fill-fee-01");
    vault.reserveLiquidity(routeId, 600_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, 600_000e18);

    // ── Step 3: Queue half of Alice's shares ──
    uint256 halfShares = vault.balanceOf(alice) / 2;
    vm.prank(alice);
    vault.requestRedeem(halfShares, alice, alice);
    assertEq(vault.queueManager().pendingCount(), 1);

    // ── Step 4: Settlement with 30k fee income ──
    uint256 feeIncome = 30_000e18;
    _simulateFeeIncome(feeIncome);
    vault.reconcileSettlementSuccess(fillId, 600_000e18, feeIncome);

    uint256 protocolFees = vault.protocolFeeAccruedAssets();
    assertGt(protocolFees, 0, "E2E05: protocol fees accrued");
    _assertBuckets();

    // ── Step 5: Governance claims protocol fees ──
    vm.prank(governance);
    vault.claimProtocolFees(feeReceiver, protocolFees);
    assertEq(vault.protocolFeeAccruedAssets(), 0, "E2E05: fees fully claimed");
    assertEq(asset.balanceOf(feeReceiver), protocolFees, "E2E05: fee receiver got fees");
    _assertBuckets();

    // ── Step 6: Process queue ──
    uint256 aliceBalBefore = asset.balanceOf(alice);
    uint256 processed = vault.processRedeemQueue(10);
    assertEq(processed, 1, "E2E05: queue processed after fee claim");
    uint256 aliceReceived = asset.balanceOf(alice) - aliceBalBefore;
    assertGt(aliceReceived, 0, "E2E05: Alice received assets from queue");
    _assertBuckets();

    // ── Step 7: Alice redeems remaining shares ──
    uint256 redeemable = vault.maxRedeem(alice);
    if (redeemable > 0) {
      vm.prank(alice);
      vault.redeem(redeemable, alice, alice);
    }
    _assertBuckets();
  }

  // ═══════════════════════════════════════════════════════════════════
  // E2E-06: Multi-LP Queue FIFO: three LPs queue, processed in order
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Three LPs queue redemptions while liquidity is locked.
  ///         Verifies FIFO ordering and equal payouts.
  function test_E2E06_MultiLP_QueueFIFO() public {
    // Zero fees for this test: isolate FIFO ordering behavior
    vm.prank(governance);
    vault.setPolicy(0, 9_500, 0, 0, 0);

    // ── Step 1: Three LPs deposit equally ──
    vm.prank(alice);
    vault.deposit(300_000e18, alice);
    vm.prank(bob);
    vault.deposit(300_000e18, bob);
    vm.prank(carol);
    vault.deposit(300_000e18, carol);

    // ── Step 2: Lock 800k ──
    bytes32 routeId = keccak256("route-fifo-01");
    vault.reserveLiquidity(routeId, 800_000e18, uint64(block.timestamp + 2 hours));
    bytes32 fillId = keccak256("fill-fifo-01");
    vault.executeFill(routeId, fillId, 800_000e18);

    // ── Step 3: All three queue full redemption ──
    uint256 aliceShares = vault.balanceOf(alice);
    uint256 bobShares = vault.balanceOf(bob);
    uint256 carolShares = vault.balanceOf(carol);

    vm.prank(alice);
    uint256 rid1 = vault.requestRedeem(aliceShares, alice, alice);
    vm.prank(bob);
    uint256 rid2 = vault.requestRedeem(bobShares, bob, bob);
    vm.prank(carol);
    uint256 rid3 = vault.requestRedeem(carolShares, carol, carol);

    assertLt(rid1, rid2, "E2E06: FIFO order alice < bob");
    assertLt(rid2, rid3, "E2E06: FIFO order bob < carol");
    assertEq(vault.queueManager().pendingCount(), 3);

    // ── Step 4: Settlement with 0 fees (clean FIFO test) ──
    vault.reconcileSettlementSuccess(fillId, 800_000e18, 0);
    _assertBuckets();

    // ── Step 5: Process queue ──
    uint256 aliceBalBefore = asset.balanceOf(alice);
    uint256 bobBalBefore = asset.balanceOf(bob);
    uint256 carolBalBefore = asset.balanceOf(carol);

    uint256 processed = vault.processRedeemQueue(10);
    assertEq(processed, 3, "E2E06: all 3 requests processed");
    assertEq(vault.queueManager().pendingCount(), 0, "E2E06: queue empty");

    uint256 aliceGot = asset.balanceOf(alice) - aliceBalBefore;
    uint256 bobGot = asset.balanceOf(bob) - bobBalBefore;
    uint256 carolGot = asset.balanceOf(carol) - carolBalBefore;

    // All deposited equal, so should receive equal (within rounding)
    assertApproxEqAbs(aliceGot, bobGot, 1e15, "E2E06: alice ~= bob payout");
    assertApproxEqAbs(bobGot, carolGot, 1e15, "E2E06: bob ~= carol payout");
    // Each should get ~300k back
    assertApproxEqAbs(aliceGot, 300_000e18, 1e15, "E2E06: alice ~= 300k");
    _assertBuckets();
  }

  // ═══════════════════════════════════════════════════════════════════
  // E2E-07: Deposit After Loss: new LP enters after NAV impairment
  // ═══════════════════════════════════════════════════════════════════
  /// @notice After a loss degrades share price, new LP deposits at fair
  ///         (depreciated) price. Later fee income benefits both proportionally.
  function test_E2E07_DepositAfterLoss_FairEntry() public {
    // No protocol fee for cleaner math
    vm.prank(governance);
    vault.setPolicy(1_000, 9_500, 2_000, 0, 1_000);

    // ── Step 1: Alice deposits 1M ──
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);
    uint256 aliceShares = vault.balanceOf(alice);

    // ── Step 2: Full cycle with total loss ──
    bytes32 r1 = keccak256("route-loss-01");
    bytes32 f1 = keccak256("fill-loss-01");
    vault.reserveLiquidity(r1, 500_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(r1, f1, 500_000e18);
    vault.reconcileSettlementLoss(f1, 500_000e18, 0);

    assertEq(vault.totalAssets(), 500_000e18, "E2E07: totalAssets = 500k after 500k loss");

    // ── Step 3: Bob deposits 500k at depreciated price ──
    vm.prank(bob);
    uint256 bobShares = vault.deposit(500_000e18, bob);
    // Bob gets ~2x more shares per dollar (price halved)
    assertGt(bobShares, aliceShares / 2, "E2E07: Bob gets more shares per dollar");
    assertEq(vault.totalAssets(), 1_000_000e18, "E2E07: totalAssets restored to 1M");

    // ── Step 4: New cycle with fee income ──
    bytes32 r2 = keccak256("route-recover-01");
    bytes32 f2 = keccak256("fill-recover-01");
    vault.reserveLiquidity(r2, 400_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(r2, f2, 400_000e18);
    _simulateFeeIncome(10_000e18);
    vault.reconcileSettlementSuccess(f2, 400_000e18, 10_000e18);

    // ── Step 5: Both redeem ──
    uint256 aliceMax2 = vault.maxRedeem(alice);
    vm.prank(alice);
    uint256 aliceOut = vault.redeem(aliceMax2, alice, alice);
    uint256 bobMax2 = vault.maxRedeem(bob);
    vm.prank(bob);
    uint256 bobOut = vault.redeem(bobMax2, bob, bob);

    // Alice lost 500k, gained share of fee income. Net loss.
    assertLt(aliceOut, 1_000_000e18, "E2E07: Alice net loss (pre-loss LP)");
    // Bob entered at fair depreciated price, roughly whole
    assertGe(bobOut, 499_000e18, "E2E07: Bob roughly whole (post-loss LP)");
    _assertBuckets();
  }

  // ═══════════════════════════════════════════════════════════════════
  // E2E-08: Reservation Expiry Cycle: reserve expires, liquidity freed, reuse
  // ═══════════════════════════════════════════════════════════════════
  /// @notice reserve -> time passes -> permissionless expire ->
  ///         re-reserve -> fill -> settle -> redeem.
  function test_E2E08_ReservationExpiry_ThenReuse() public {
    // ── Step 1: Deposit ──
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    // ── Step 2: Reserve with short expiry ──
    bytes32 routeId1 = keccak256("route-expiry-01");
    uint64 expiry = uint64(block.timestamp + 30 minutes);
    vault.reserveLiquidity(routeId1, 500_000e18, expiry);
    assertEq(vault.reservedLiquidityAssets(), 500_000e18);

    // ── Step 3: Expiry elapses ──
    vm.warp(block.timestamp + 31 minutes);

    // ── Step 4: Anyone can expire the reservation (permissionless) ──
    vm.prank(carol);
    vault.expireReservation(routeId1);
    assertEq(vault.reservedLiquidityAssets(), 0, "E2E08: reserved cleared");
    assertEq(vault.freeLiquidityAssets(), 1_000_000e18, "E2E08: free restored");
    _assertBuckets();

    // ── Step 5: Re-reserve the freed liquidity ──
    bytes32 routeId2 = keccak256("route-reuse-01");
    bytes32 fillId2 = keccak256("fill-reuse-01");
    vault.reserveLiquidity(routeId2, 500_000e18, uint64(block.timestamp + 2 hours));
    vault.executeFill(routeId2, fillId2, 500_000e18);

    // ── Step 6: Settle and redeem ──
    _simulateFeeIncome(2_000e18);
    vault.reconcileSettlementSuccess(fillId2, 500_000e18, 2_000e18);

    uint256 aliceOut = _claimFeesAndRedeem(alice);
    assertGt(aliceOut, 1_000_000e18, "E2E08: LP profited from fee");
    _assertBuckets();
  }
}
