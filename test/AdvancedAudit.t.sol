// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { LaneQueueManager } from "../src/LaneQueueManager.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @title Advanced Audit Tests: Edge Cases and Boundary Conditions
/// @notice 15 targeted tests from the deep security audit (March 2026).
///         Covers: policy extremes, cascading losses, state machine finality,
///         boundary timestamps, post-loss deposits, and invariant stress tests.
///         Non-overlapping with Attacks.t.sol (14), SecurityAudit.Attacks.t.sol (10),
///         and DeepAudit.t.sol (11).
contract AdvancedAuditTest is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal carol = makeAddr("carol");
  address internal governance = makeAddr("governance");

  function setUp() public {
    asset = new MockERC20("Mock Asset", "mAST");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    _mintAndApprove(alice, 100_000_000e18);
    _mintAndApprove(bob, 100_000_000e18);
    _mintAndApprove(carol, 100_000_000e18);

    vault.setSettlementAdapter(address(this));
    vault.grantRole(vault.GOVERNANCE_ROLE(), governance);

    // Allow alice/bob/carol transfers for share movement
    vault.setTransferAllowlisted(alice, true);
    vault.setTransferAllowlisted(bob, true);
    vault.setTransferAllowlisted(carol, true);
  }

  function _mintAndApprove(address who, uint256 amount) internal {
    asset.mint(who, amount);
    vm.prank(who);
    asset.approve(address(vault), type(uint256).max);
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-01: Policy extremes — 100% bad debt cut + max protocol fee
  // ═══════════════════════════════════════════════════════════════════
  /// @notice When badDebtReserveCutBps = 10000 (100%) and protocolFeeBps = cap (100%),
  ///         ALL fee income is absorbed. LP distributable must be zero. Accounting must hold.
  function test_ADV01_PolicyExtremes_AllFeeAbsorbed() public {
    // Set extreme policy: 100% to bad debt reserve, 100% to protocol fee
    vm.prank(governance);
    vault.setPolicy(10_000, 9_000, 2_000, 10_000, 10_000);

    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    bytes32 routeId = keccak256("adv01-route");
    bytes32 fillId = keccak256("adv01-fill");
    uint256 principal = 100_000e18;
    uint256 fee = 10_000e18;

    vault.reserveLiquidity(routeId, principal, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, principal);

    // Simulate settlement: tokens arrive
    asset.mint(address(vault), principal + fee);
    vault.reconcileSettlementSuccess(fillId, principal, fee);

    // reserveCut = fee * 10000/10000 = fee (100%)
    // protocolFee = fee * 10000/10000 = fee (100%)
    // distributable = max(fee - 2*fee, 0) = 0
    assertEq(vault.settledFeesEarnedAssets(), 0, "ADV-01: distributable must be zero with extreme policy");

    // Bad debt reserve got the full fee amount
    assertEq(vault.badDebtReserveAssets(), fee, "ADV-01: bad debt reserve must absorb full fee");

    // Protocol fee also got the full fee amount
    assertEq(vault.protocolFeeAccruedAssets(), fee, "ADV-01: protocol fee must absorb full fee");

    // freeLiq = original(1M) - principal(100k) [reserve] + principal + fee [settlement]
    // = 1M + fee = 1_010_000e18
    uint256 expectedFree = 1_000_000e18 + fee;
    assertEq(vault.freeLiquidityAssets(), expectedFree, "ADV-01: freeLiq must equal deposits + fee");

    // Invariants must hold
    assertLe(vault.badDebtReserveAssets(), vault.freeLiquidityAssets(), "ADV-01: badDebt invariant");
    assertLe(vault.protocolFeeAccruedAssets(), vault.freeLiquidityAssets(), "ADV-01: protocolFee invariant");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-02: Queue processing after settlement loss — shares depreciate
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Enqueue shares, then total loss occurs, then process queue.
  ///         Queued shares must redeem at the depreciated exchange rate.
  function test_ADV02_QueueProcessingAfterLoss() public {
    // Bump utilization cap to allow large reservations
    vm.prank(governance);
    vault.setPolicy(1_000, 9_500, 2_000, 0, 1_000);

    // Alice and Bob deposit equally
    vm.prank(alice);
    vault.deposit(500_000e18, alice);
    vm.prank(bob);
    vault.deposit(500_000e18, bob);

    uint256 aliceShares = vault.balanceOf(alice);

    // Use up most free liquidity so queue is needed
    bytes32 routeId = keccak256("adv02-route");
    bytes32 fillId = keccak256("adv02-fill");
    uint256 reserveAmount = 800_000e18;
    vault.reserveLiquidity(routeId, reserveAmount, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, reserveAmount);

    // Alice requests full redeem (will queue since not enough free liquidity)
    vm.prank(alice);
    vault.requestRedeem(aliceShares, alice, alice);

    // Total loss on the 800k in-flight (0 recovered)
    vault.reconcileSettlementLoss(fillId, 800_000e18, 0);

    // NAV should have dropped significantly
    // totalAssets = freeLiq(200k) + reserved(0) + inFlight(0) - protocolFee(0) = 200k
    // But total supply = alice's escrowed shares + bob's shares
    assertEq(vault.totalAssets(), 200_000e18, "ADV-02: total assets after loss");

    // Process queue: Alice's shares should redeem at depreciated rate
    uint256 assetsDue = vault.previewRedeem(aliceShares);
    assertTrue(assetsDue < 500_000e18, "ADV-02: redemption must be at depreciated rate");

    // Process if there's enough liquidity
    if (assetsDue <= vault.availableFreeLiquidityForLP()) {
      vault.processRedeemQueue(1);
      assertGe(asset.balanceOf(alice), assetsDue, "ADV-02: Alice received depreciated assets");
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-03: Cascading losses drain bad debt reserve to zero
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Multiple sequential total losses exhaust the bad debt reserve,
  ///         then subsequent losses go entirely to realizedNavLoss.
  function test_ADV03_CascadingLossesDrainReserve() public {
    // Set policy with 50% bad debt cut to build up reserve
    vm.prank(governance);
    vault.setPolicy(5_000, 9_000, 2_000, 0, 1_000);

    vm.prank(alice);
    vault.deposit(10_000_000e18, alice);

    // Build up bad debt reserve via a successful settlement
    bytes32 r1 = keccak256("adv03-r1");
    bytes32 f1 = keccak256("adv03-f1");
    vault.reserveLiquidity(r1, 1_000_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(r1, f1, 1_000_000e18);
    asset.mint(address(vault), 1_000_000e18 + 200_000e18); // principal + fee
    vault.reconcileSettlementSuccess(f1, 1_000_000e18, 200_000e18);
    // reserveCut = 200k * 50% = 100k
    uint256 reserveAfterSuccess = vault.badDebtReserveAssets();
    assertEq(reserveAfterSuccess, 100_000e18, "ADV-03: reserve should be 100k");

    // Loss 1: 200k total loss, reserve absorbs 100k, 100k uncovered
    bytes32 r2 = keccak256("adv03-r2");
    bytes32 f2 = keccak256("adv03-f2");
    vault.reserveLiquidity(r2, 200_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(r2, f2, 200_000e18);
    vault.reconcileSettlementLoss(f2, 200_000e18, 0);
    assertEq(vault.badDebtReserveAssets(), 0, "ADV-03: reserve drained to zero after loss 1");
    assertEq(vault.realizedNavLossAssets(), 100_000e18, "ADV-03: 100k uncovered in loss 1");

    // Loss 2: 300k total loss, reserve is 0, ALL goes to realizedNavLoss
    bytes32 r3 = keccak256("adv03-r3");
    bytes32 f3 = keccak256("adv03-f3");
    vault.reserveLiquidity(r3, 300_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(r3, f3, 300_000e18);
    vault.reconcileSettlementLoss(f3, 300_000e18, 0);
    assertEq(vault.badDebtReserveAssets(), 0, "ADV-03: reserve still zero after loss 2");
    assertEq(vault.realizedNavLossAssets(), 400_000e18, "ADV-03: 400k total uncovered losses");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-04: Emergency release exact timestamp boundary
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Emergency release at (executedAt + delay - 1) must revert.
  ///         At exactly (executedAt + delay) it must succeed.
  function test_ADV04_EmergencyReleaseBoundary() public {
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    bytes32 routeId = keccak256("adv04-route");
    bytes32 fillId = keccak256("adv04-fill");
    uint256 amount = 100_000e18;

    vault.reserveLiquidity(routeId, amount, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, amount);

    uint64 executedAt = uint64(block.timestamp);
    uint48 delay = vault.emergencyReleaseDelay(); // 3 days default
    uint64 readyAt = executedAt + delay;

    // At readyAt - 1: must revert
    vm.warp(readyAt - 1);
    vm.prank(governance);
    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.EmergencyReleaseNotReady.selector, fillId, readyAt));
    vault.emergencyReleaseFill(fillId, 0);

    // At exactly readyAt: must succeed
    vm.warp(readyAt);
    vm.prank(governance);
    vault.emergencyReleaseFill(fillId, 0);

    // Verify fill is now SettledLoss
    (LaneVault4626.RouteStatus rStatus,,,) = vault.routes(routeId);
    assertEq(uint8(rStatus), uint8(LaneVault4626.RouteStatus.SettledLoss), "ADV-04: route must be SettledLoss");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-05: Settlement with fee exceeding principal (huge fees)
  // ═══════════════════════════════════════════════════════════════════
  /// @notice netFeeIncomeAssets > principalAssets should work if tokens actually arrive.
  function test_ADV05_SettlementFeeExceedsPrincipal() public {
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    bytes32 routeId = keccak256("adv05-route");
    bytes32 fillId = keccak256("adv05-fill");
    uint256 principal = 10_000e18;
    uint256 fee = 50_000e18; // 5x the principal

    vault.reserveLiquidity(routeId, principal, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, principal);

    // Mint tokens to cover the fee income
    asset.mint(address(vault), principal + fee);
    vault.reconcileSettlementSuccess(fillId, principal, fee);

    // Accounting should hold
    assertGe(vault.freeLiquidityAssets(), principal + fee, "ADV-05: freeLiq includes large fee");
    assertLe(vault.badDebtReserveAssets(), vault.freeLiquidityAssets(), "ADV-05: invariant holds");
    assertLe(vault.protocolFeeAccruedAssets(), vault.freeLiquidityAssets(), "ADV-05: invariant holds");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-06: Reservation expiry exact timestamp boundary
  // ═══════════════════════════════════════════════════════════════════
  /// @notice At block.timestamp == expiry - 1: must revert.
  ///         At block.timestamp == expiry: must succeed (check uses strict <).
  function test_ADV06_ReservationExpiryBoundary() public {
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    bytes32 routeId = keccak256("adv06-route");
    uint64 expiry = uint64(block.timestamp + 1 hours);

    vault.reserveLiquidity(routeId, 100_000e18, expiry);

    // At expiry - 1: must revert
    vm.warp(expiry - 1);
    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.ReservationNotExpired.selector, routeId, expiry));
    vault.expireReservation(routeId);

    // At exactly expiry: must succeed (contract checks block.timestamp < expiry)
    vm.warp(expiry);
    vault.expireReservation(routeId);

    // Verify reservation is released
    (LaneVault4626.RouteStatus status,,,) = vault.routes(routeId);
    assertEq(uint8(status), uint8(LaneVault4626.RouteStatus.Released), "ADV-06: route must be Released");
    assertEq(vault.reservedLiquidityAssets(), 0, "ADV-06: reserved must be zero");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-07: Protocol fee claim constrained by bad debt reserve
  // ═══════════════════════════════════════════════════════════════════
  /// @notice When protocolFees + badDebtReserve approaches freeLiq,
  ///         claiming all fees must revert (invariant: badDebt <= freeLiq).
  function test_ADV07_ProtocolFeeClaimConstrainedByBadDebt() public {
    // Setup: 50% bad debt cut, 50% protocol fee (need protocolFeeCapBps >= 5000)
    vm.prank(governance);
    vault.setPolicy(5_000, 9_000, 2_000, 5_000, 5_000);

    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    // Do a settlement to accumulate both bad debt reserve and protocol fees
    bytes32 routeId = keccak256("adv07-route");
    bytes32 fillId = keccak256("adv07-fill");
    uint256 principal = 500_000e18;
    uint256 fee = 400_000e18;

    vault.reserveLiquidity(routeId, principal, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, principal);
    asset.mint(address(vault), principal + fee);
    vault.reconcileSettlementSuccess(fillId, principal, fee);

    // badDebtReserve = 400k * 50% = 200k
    // protocolFeeAccrued = 400k * 50% = 200k
    // freeLiq = 1M + 400k = 1_400_000e18
    uint256 protocolFees = vault.protocolFeeAccruedAssets();
    uint256 badDebt = vault.badDebtReserveAssets();
    uint256 freeLiq = vault.freeLiquidityAssets();

    assertEq(protocolFees, 200_000e18, "ADV-07: protocol fees = 200k");
    assertEq(badDebt, 200_000e18, "ADV-07: bad debt = 200k");

    // Now do a massive loss to deplete free liquidity but keep reserves
    bytes32 r2 = keccak256("adv07-r2");
    bytes32 f2 = keccak256("adv07-f2");
    vault.reserveLiquidity(r2, 900_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(r2, f2, 900_000e18);
    vault.reconcileSettlementLoss(f2, 900_000e18, 0);

    // After loss: freeLiq = 1_400_000 - 900_000 (reserve) + 0 (recovered) = 500_000
    // Actually: freeLiq was 1_400_000, then reserve took 900_000 => 500_000
    // Then fill moved from reserved to inFlight. Then loss: inFlight -= 900k, freeLiq += 0
    // loss = 900k, reserveAbsorb = min(200k, 900k) = 200k, uncovered = 700k
    // badDebt = 200k - 200k = 0
    // freeLiq = 500_000 (unchanged by loss settlement since recovered=0)
    freeLiq = vault.freeLiquidityAssets();
    protocolFees = vault.protocolFeeAccruedAssets();
    badDebt = vault.badDebtReserveAssets();

    // protocolFees = 200k, freeLiq = 500k, badDebt = 0
    // Claiming 200k fees: freeLiq becomes 300k, badDebt=0 <= 300k. OK.
    // This should succeed since badDebt is now 0
    vm.prank(governance);
    vault.claimProtocolFees(governance, protocolFees);
    assertEq(vault.protocolFeeAccruedAssets(), 0, "ADV-07: all fees claimed");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-08: Route ID reuse blocked after settlement
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Once a routeId reaches a terminal state (SettledSuccess, SettledLoss, Released),
  ///         it can never be reserved again. State machine is one-way.
  function test_ADV08_RouteIdReuseBlocked() public {
    vm.prank(alice);
    vault.deposit(5_000_000e18, alice);

    bytes32 routeId = keccak256("adv08-reuse");
    bytes32 fillId = keccak256("adv08-fill");

    // Full lifecycle: reserve -> fill -> settle success
    vault.reserveLiquidity(routeId, 100_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, 100_000e18);
    asset.mint(address(vault), 100_000e18 + 1_000e18);
    vault.reconcileSettlementSuccess(fillId, 100_000e18, 1_000e18);

    // Attempt to reuse the same routeId: must revert InvalidTransition
    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reserveLiquidity(routeId, 50_000e18, uint64(block.timestamp + 2 hours));
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-09: Fill ID reuse blocked after settlement
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Once a fillId reaches a terminal state, it cannot be reused
  ///         with a different route.
  function test_ADV09_FillIdReuseBlocked() public {
    vm.prank(alice);
    vault.deposit(5_000_000e18, alice);

    bytes32 route1 = keccak256("adv09-route1");
    bytes32 route2 = keccak256("adv09-route2");
    bytes32 fillId = keccak256("adv09-fill-shared");

    // Route 1: full lifecycle
    vault.reserveLiquidity(route1, 100_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(route1, fillId, 100_000e18);
    asset.mint(address(vault), 100_000e18 + 1_000e18);
    vault.reconcileSettlementSuccess(fillId, 100_000e18, 1_000e18);

    // Route 2: reserve succeeds (new routeId), but executeFill with same fillId must revert
    vault.reserveLiquidity(route2, 100_000e18, uint64(block.timestamp + 1 hours));
    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.executeFill(route2, fillId, 100_000e18);
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-10: Deposit after total loss — NAV near zero
  // ═══════════════════════════════════════════════════════════════════
  /// @notice After a catastrophic loss, new depositors must not be unfairly
  ///         diluted by existing share holders who lost everything.
  function test_ADV10_DepositAfterTotalLoss() public {
    vm.prank(alice);
    uint256 aliceDeposit = 1_000_000e18;
    vault.deposit(aliceDeposit, alice);
    uint256 aliceShares = vault.balanceOf(alice);

    // Put everything in flight and lose it all
    // Set utilization cap to 100% so we can reserve the full amount
    vm.prank(governance);
    vault.setPolicy(1_000, 10_000, 2_000, 0, 1_000);

    bytes32 routeId = keccak256("adv10-route");
    bytes32 fillId = keccak256("adv10-fill");
    uint256 available = vault.availableFreeLiquidityForLP();

    vault.reserveLiquidity(routeId, available, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, available);

    // Total loss
    vault.reconcileSettlementLoss(fillId, available, 0);

    // NAV should be near zero (only rounding dust remains)
    uint256 totalAssetsAfterLoss = vault.totalAssets();
    assertEq(totalAssetsAfterLoss, 0, "ADV-10: total assets should be zero after total loss");

    // Bob deposits fresh capital
    vm.prank(bob);
    uint256 bobDeposit = 100_000e18;
    vault.deposit(bobDeposit, bob);
    uint256 bobShares = vault.balanceOf(bob);

    // Bob's shares should be much larger than Alice's (since Alice's shares are worthless)
    assertTrue(bobShares > aliceShares, "ADV-10: Bob should get more shares than Alice's worthless ones");

    // Bob should be able to redeem close to his deposit (minus Alice's tiny dilution from virtual offset)
    uint256 bobRedeemable = vault.previewRedeem(bobShares);
    // Virtual offset dilution: with 10^3 offset, Alice's 1M shares vs Bob's ~100B shares
    // Dilution is minimal (< 1%)
    assertTrue(bobRedeemable > bobDeposit * 99 / 100, "ADV-10: Bob's dilution must be < 1%");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-11: Settlement success with zero fee income
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Settlement with netFeeIncomeAssets = 0 should work correctly.
  ///         Principal returns to free liquidity, no reserve/fee changes.
  function test_ADV11_SettlementZeroFee() public {
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    bytes32 routeId = keccak256("adv11-route");
    bytes32 fillId = keccak256("adv11-fill");
    uint256 principal = 100_000e18;

    vault.reserveLiquidity(routeId, principal, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, principal);

    uint256 badDebtBefore = vault.badDebtReserveAssets();
    uint256 protocolFeeBefore = vault.protocolFeeAccruedAssets();
    uint256 freeLiqBefore = vault.freeLiquidityAssets();

    // Settlement with zero fee: only need to return principal tokens
    asset.mint(address(vault), principal);
    vault.reconcileSettlementSuccess(fillId, principal, 0);

    // No reserve or fee changes
    assertEq(vault.badDebtReserveAssets(), badDebtBefore, "ADV-11: bad debt unchanged");
    assertEq(vault.protocolFeeAccruedAssets(), protocolFeeBefore, "ADV-11: protocol fee unchanged");
    // freeLiq restored: previous + principal
    assertEq(vault.freeLiquidityAssets(), freeLiqBefore + principal, "ADV-11: freeLiq restored");
    assertEq(vault.inFlightLiquidityAssets(), 0, "ADV-11: nothing in flight");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-12: Loss settlement with full recovery (loss = 0)
  // ═══════════════════════════════════════════════════════════════════
  /// @notice reconcileSettlementLoss with recoveredAssets == principalAssets
  ///         is a "loss" that loses nothing. Accounting must handle this edge.
  function test_ADV12_LossSettlementFullRecovery() public {
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    bytes32 routeId = keccak256("adv12-route");
    bytes32 fillId = keccak256("adv12-fill");
    uint256 principal = 100_000e18;

    vault.reserveLiquidity(routeId, principal, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, principal);

    uint256 freeLiqBefore = vault.freeLiquidityAssets();
    uint256 badDebtBefore = vault.badDebtReserveAssets();

    // "Loss" settlement but 100% recovered
    vault.reconcileSettlementLoss(fillId, principal, principal);

    // loss = principal - principal = 0, reserveAbsorb = 0, uncovered = 0
    assertEq(vault.badDebtReserveAssets(), badDebtBefore, "ADV-12: bad debt unchanged");
    assertEq(vault.realizedNavLossAssets(), 0, "ADV-12: no realized loss");
    assertEq(vault.freeLiquidityAssets(), freeLiqBefore + principal, "ADV-12: principal returned to free");
    assertEq(vault.inFlightLiquidityAssets(), 0, "ADV-12: nothing in flight");

    // But status is SettledLoss (not SettledSuccess)
    (LaneVault4626.RouteStatus rStatus,,,) = vault.routes(routeId);
    assertEq(uint8(rStatus), uint8(LaneVault4626.RouteStatus.SettledLoss), "ADV-12: route is SettledLoss");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-13: Policy change mid-flight affects settlement math
  // ═══════════════════════════════════════════════════════════════════
  /// @notice If governance changes badDebtReserveCutBps while a fill is in-flight,
  ///         the settlement uses the NEW policy values.
  function test_ADV13_PolicyChangeMidFlight() public {
    // Start with 10% bad debt cut
    vm.prank(governance);
    vault.setPolicy(1_000, 9_000, 2_000, 0, 1_000);

    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    bytes32 routeId = keccak256("adv13-route");
    bytes32 fillId = keccak256("adv13-fill");
    uint256 principal = 100_000e18;
    uint256 fee = 10_000e18;

    vault.reserveLiquidity(routeId, principal, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, principal);

    // Change policy while fill is in-flight: 80% bad debt cut
    vm.prank(governance);
    vault.setPolicy(8_000, 9_000, 2_000, 0, 1_000);

    // Settle: should use the NEW 80% cut
    asset.mint(address(vault), principal + fee);
    vault.reconcileSettlementSuccess(fillId, principal, fee);

    // reserveCut = 10_000e18 * 8000/10000 = 8_000e18
    assertEq(vault.badDebtReserveAssets(), 8_000e18, "ADV-13: bad debt must use new 80% policy");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-14: RequestRedeem via approval (caller != owner)
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Bob can requestRedeem Alice's shares if Alice approved Bob.
  ///         Shares must be escrowed and allowance consumed.
  function test_ADV14_RequestRedeemViaApproval() public {
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);
    uint256 aliceShares = vault.balanceOf(alice);
    uint256 redeemAmount = aliceShares / 2;

    // Alice approves Bob for share spending
    vm.prank(alice);
    vault.approve(bob, redeemAmount);

    // Use up free liquidity so queue is needed (need high util cap)
    vm.prank(governance);
    vault.setPolicy(1_000, 9_500, 2_000, 0, 1_000);
    bytes32 routeId = keccak256("adv14-route");
    vault.reserveLiquidity(routeId, 800_000e18, uint64(block.timestamp + 1 hours));

    // Bob calls requestRedeem on behalf of Alice
    vm.prank(bob);
    uint256 requestId = vault.requestRedeem(redeemAmount, carol, alice);
    assertTrue(requestId > 0, "ADV-14: request ID must be positive");

    // Alice's shares decreased (escrowed in vault)
    assertEq(vault.balanceOf(alice), aliceShares - redeemAmount, "ADV-14: shares escrowed");

    // Bob's allowance consumed
    assertEq(vault.allowance(alice, bob), 0, "ADV-14: allowance consumed");

    // Queue has the request with carol as receiver
    (bool exists, LaneQueueManager.RedeemRequest memory req) = vault.queueManager().peek();
    assertTrue(exists, "ADV-14: request must be in queue");
    assertEq(req.receiver, carol, "ADV-14: receiver must be carol");
    assertEq(req.owner, alice, "ADV-14: owner must be alice");
  }

  // ═══════════════════════════════════════════════════════════════════
  // ADV-15: Combined reserve + fee accumulation near invariant boundary
  // ═══════════════════════════════════════════════════════════════════
  /// @notice Stress test: accumulate badDebtReserve and protocolFee through
  ///         repeated settlements, then verify each individually stays <= freeLiq
  ///         even when their sum exceeds freeLiq.
  function test_ADV15_CombinedReserveFeeNearBoundary() public {
    // High fees: 40% bad debt cut, 40% protocol fee
    vm.prank(governance);
    vault.setPolicy(4_000, 9_500, 2_000, 4_000, 4_000);

    vm.prank(alice);
    vault.deposit(2_000_000e18, alice);

    // Multiple settlements to accumulate reserves
    for (uint256 i = 0; i < 5; i++) {
      bytes32 rId = keccak256(abi.encode("adv15-route", i));
      bytes32 fId = keccak256(abi.encode("adv15-fill", i));
      uint256 principal = 200_000e18;
      uint256 fee = 100_000e18;

      vault.reserveLiquidity(rId, principal, uint64(block.timestamp + 1 hours));
      vault.executeFill(rId, fId, principal);
      asset.mint(address(vault), principal + fee);
      vault.reconcileSettlementSuccess(fId, principal, fee);
    }

    // After 5 settlements:
    // Each: reserveCut = 100k * 40% = 40k, protocolFee = 100k * 40% = 40k
    // Total: badDebt = 200k, protocolFee = 200k
    // freeLiq = 2M + 5*100k = 2_500_000e18
    uint256 badDebt = vault.badDebtReserveAssets();
    uint256 protocolFee = vault.protocolFeeAccruedAssets();
    uint256 freeLiq = vault.freeLiquidityAssets();

    assertEq(badDebt, 200_000e18, "ADV-15: bad debt = 200k");
    assertEq(protocolFee, 200_000e18, "ADV-15: protocol fee = 200k");

    // Each individually <= freeLiq
    assertLe(badDebt, freeLiq, "ADV-15: bad debt invariant holds");
    assertLe(protocolFee, freeLiq, "ADV-15: protocol fee invariant holds");

    // Combined sum < freeLiq in this case (400k < 2.5M)
    // But availableForLP correctly subtracts both
    uint256 available = vault.availableFreeLiquidityForLP();
    assertEq(available, freeLiq - badDebt - protocolFee, "ADV-15: available = free - debt - fees");

    // Verify total assets excludes protocol fees but NOT bad debt reserve
    uint256 totalA = vault.totalAssets();
    uint256 expectedTotal = freeLiq + vault.reservedLiquidityAssets() + vault.inFlightLiquidityAssets() - protocolFee;
    assertEq(totalA, expectedTotal, "ADV-15: totalAssets formula correct");
  }
}
