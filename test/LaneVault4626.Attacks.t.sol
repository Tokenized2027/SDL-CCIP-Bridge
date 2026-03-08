// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { LaneQueueManager } from "../src/LaneQueueManager.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @title LaneVault4626 Attack Scenario Tests
/// @notice Tests for DeFi attack vectors from the enhanced SC Auditor methodology.
contract LaneVault4626AttacksTest is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal attacker = makeAddr("attacker");
  address internal receiver = makeAddr("receiver");

  function setUp() public {
    asset = new MockERC20("Mock Asset", "mAST");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    _mintAndApprove(alice, 1_000_000);
    _mintAndApprove(bob, 1_000_000);
    _mintAndApprove(attacker, 1_000_000);

    vault.setPolicy(1_000, 9_000, 2_000, 0, 1_000);
    vault.setSettlementAdapter(address(this));
  }

  // ──────────────── Attack #1: Donation Attack ────────────────
  /// @notice Direct token transfer should NOT inflate share price (virtual accounting).
  function testAttack_DonationDoesNotInflateSharePrice() public {
    vm.prank(alice);
    vault.deposit(10_000, alice);

    uint256 sharePriceBefore = vault.previewRedeem(1_000);

    // Attacker donates tokens directly to vault
    vm.prank(attacker);
    asset.transfer(address(vault), 100_000);

    uint256 sharePriceAfter = vault.previewRedeem(1_000);

    assertEq(sharePriceBefore, sharePriceAfter, "donation must not change share price (virtual accounting)");
  }

  // ──────────────── Attack #14: Read-Only Reentrancy ────────────────
  /// @notice View functions should return consistent state during normal operations.
  function testAttack_ViewFunctionsConsistentDuringOperations() public {
    vm.prank(alice);
    vault.deposit(50_000, alice);

    // Snapshot view state
    uint256 totalAssetsBefore = vault.totalAssets();
    uint256 maxWithdrawBefore = vault.maxWithdraw(alice);

    // Perform a reserve operation
    bytes32 routeId = keccak256("ro-reentrancy-route");
    vault.reserveLiquidity(routeId, 10_000, uint64(block.timestamp + 1 hours));

    // View state after should reflect the reservation
    uint256 totalAssetsAfter = vault.totalAssets();
    uint256 maxWithdrawAfter = vault.maxWithdraw(alice);

    assertEq(totalAssetsBefore, totalAssetsAfter, "totalAssets should not change from reservation");
    assertLt(maxWithdrawAfter, maxWithdrawBefore, "maxWithdraw must decrease after reservation");
  }

  // ──────────────── Attack #21: Fee-on-Transfer Deposit ────────────────
  /// @notice With standard ERC-20, deposited amount equals credited amount.
  function testAttack_StandardERC20DepositAmountEqualsCredit() public {
    uint256 depositAmount = 5_000;
    uint256 balanceBefore = asset.balanceOf(address(vault));

    vm.prank(alice);
    vault.deposit(depositAmount, alice);

    uint256 balanceAfter = asset.balanceOf(address(vault));
    uint256 actualReceived = balanceAfter - balanceBefore;

    assertEq(actualReceived, depositAmount, "vault must receive exact deposit amount for standard ERC-20");
    assertEq(vault.freeLiquidityAssets(), depositAmount, "free liquidity must equal deposit for standard ERC-20");
  }

  // ──────────────── Attack #23: Cross-Chain Message Replay ────────────────
  /// @notice Replay of the same settlement message must revert.
  function testAttack_SettlementDoubleReplay() public {
    vm.prank(alice);
    vault.deposit(100_000, alice);

    bytes32 routeA = keccak256("replay-route-a");
    bytes32 fillA = keccak256("replay-fill-a");

    vault.reserveLiquidity(routeA, 10_000, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeA, fillA, 10_000);

    // First settlement: success (fee income arrives via CCIP)
    asset.mint(address(vault), 500);
    vault.reconcileSettlementSuccess(fillA, 10_000, 500);

    // Second settlement attempt: must revert (fill already settled)
    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reconcileSettlementSuccess(fillA, 10_000, 500);

    // Third: try loss path on same fill: must also revert
    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reconcileSettlementLoss(fillA, 10_000, 9_000);
  }

  // ──────────────── Attack #25: Inflation Attack (ERC-4626 First Depositor) ────────────────
  /// @notice Virtual decimals offset prevents first-depositor share manipulation.
  function testAttack_InflationAttackMitigatedByVirtualOffset() public {
    // Attacker deposits minimal amount
    vm.prank(attacker);
    vault.deposit(1, attacker);

    uint256 attackerShares = vault.balanceOf(attacker);
    assertGt(attackerShares, 0, "attacker must get shares");

    // Legitimate user deposits large amount
    vm.prank(alice);
    vault.deposit(100_000, alice);

    uint256 aliceShares = vault.balanceOf(alice);
    assertGt(aliceShares, 0, "alice must get shares");

    // Alice's shares should be proportional (not rounded to zero)
    uint256 aliceAssets = vault.previewRedeem(aliceShares);
    assertGe(aliceAssets, 99_999, "alice must not lose more than 1 wei to rounding");
  }

  // ──────────────── Attack: Settlement with Fake Fill ID ────────────────
  /// @notice Adapter must reject settlement for non-existent fills.
  function testAttack_SettlementWithFakeFillId() public {
    vm.prank(alice);
    vault.deposit(50_000, alice);

    bytes32 fakeFill = keccak256("non-existent-fill");

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reconcileSettlementSuccess(fakeFill, 10_000, 500);

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reconcileSettlementLoss(fakeFill, 10_000, 9_000);
  }

  // ──────────────── Attack: Drain via maxUtilization Manipulation ────────────────
  /// @notice Governance setting maxUtilization to 100% should not drain vault.
  function testAttack_MaxUtilization100PercentDoesNotDrainLP() public {
    vm.prank(alice);
    vault.deposit(100_000, alice);

    // Governance sets max utilization to 100%
    vault.setPolicy(1_000, 10_000, 0, 0, 1_000);

    // Reserve maximum liquidity
    bytes32 routeId = keccak256("max-util-route");
    vault.reserveLiquidity(routeId, 100_000, uint64(block.timestamp + 1 hours));

    // LP cannot withdraw while fully reserved
    assertEq(vault.maxWithdraw(alice), 0, "no withdrawals when fully reserved");

    // But total assets is preserved
    assertEq(vault.totalAssets(), 100_000, "total assets must be preserved");

    // Release returns liquidity
    vault.releaseReservation(routeId);
    assertEq(vault.maxWithdraw(alice), 100_000, "full liquidity restored after release");
  }

  // ──────────────── Attack: Queue Starvation ────────────────
  /// @notice Reserved liquidity blocking all redemptions should not lose user funds.
  function testAttack_QueueStarvationDoesNotLoseFunds() public {
    vm.prank(alice);
    vault.deposit(100_000, alice);

    // Reserve 90% of liquidity
    bytes32 routeId = keccak256("starvation-route");
    vault.reserveLiquidity(routeId, 90_000, uint64(block.timestamp + 1 hours));

    // Alice queues a large redemption (she has shares worth 100k assets)
    uint256 aliceShares = vault.balanceOf(alice);
    uint256 halfShares = aliceShares / 2;
    vm.prank(alice);
    vault.requestRedeem(halfShares, alice, alice);

    // Process queue - only partial (10k free liquidity)
    uint256 processed = vault.processRedeemQueue(1);

    // Queue should NOT process because 50k > 10k available
    assertEq(processed, 0, "queue should not process when insufficient liquidity");

    // After settlement releases liquidity, queue can be processed
    vault.executeFill(routeId, keccak256("starvation-fill"), 90_000);
    vault.reconcileSettlementSuccess(keccak256("starvation-fill"), 90_000, 0);

    processed = vault.processRedeemQueue(1);
    assertEq(processed, 1, "queue should process after liquidity returns");
  }

  // ──────────────── Attack: Reservation Expiry Enforcement ────────────────
  /// @notice Expired reservations can be permissionlessly released.
  function testAttack_ExpiredReservationCanBeReleased() public {
    vm.prank(alice);
    vault.deposit(100_000, alice);

    bytes32 routeId = keccak256("expiry-route");
    uint64 expiry = uint64(block.timestamp + 1 hours);
    vault.reserveLiquidity(routeId, 50_000, expiry);

    // Cannot expire before expiry
    vm.prank(attacker);
    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.ReservationNotExpired.selector, routeId, expiry));
    vault.expireReservation(routeId);

    // Warp past expiry
    vm.warp(expiry + 1);

    // Anyone can expire it (permissionless)
    vm.prank(attacker);
    vault.expireReservation(routeId);

    // Liquidity is restored
    assertEq(vault.freeLiquidityAssets(), 100_000, "liquidity restored after expiry");
    assertEq(vault.reservedLiquidityAssets(), 0, "reserved should be zero after expiry");
  }

  // ──────────────── Attack #12: Unauthorized Access ────────────────
  /// @notice Random addresses cannot call privileged functions.
  function testAttack_UnauthorizedAccessReverts() public {
    vm.prank(alice);
    vault.deposit(50_000, alice);

    // Attacker tries OPS functions
    vm.prank(attacker);
    vm.expectRevert();
    vault.reserveLiquidity(keccak256("attack"), 1_000, uint64(block.timestamp + 1));

    vm.prank(attacker);
    vm.expectRevert();
    vault.processRedeemQueue(1);

    // Attacker tries GOVERNANCE functions
    vm.prank(attacker);
    vm.expectRevert();
    vault.setPolicy(0, 0, 0, 0, 0);

    vm.prank(attacker);
    vm.expectRevert();
    vault.setSettlementAdapter(attacker);

    vm.prank(attacker);
    vm.expectRevert();
    vault.claimProtocolFees(attacker, 1);

    // Attacker tries SETTLEMENT functions
    vm.prank(attacker);
    vm.expectRevert();
    vault.reconcileSettlementSuccess(keccak256("fake"), 1, 0);

    // Attacker tries PAUSER functions
    vm.prank(attacker);
    vm.expectRevert();
    vault.setPauseFlags(true, true, true);
  }

  // ──────────────── Attack #13: Pause Bypass ────────────────
  /// @notice Paused vault still allows withdrawals (safety exit).
  function testAttack_PausedVaultAllowsWithdrawals() public {
    vm.prank(alice);
    vault.deposit(50_000, alice);

    vault.setPauseFlags(false, true, false);

    // Deposits blocked
    vm.prank(bob);
    vm.expectRevert(LaneVault4626.DepositPaused.selector);
    vault.deposit(1, bob);

    // Withdrawals still work
    vm.prank(alice);
    vault.withdraw(1_000, alice, alice);
    assertEq(asset.balanceOf(alice), 951_000, "withdrawal should succeed while deposit is paused");
  }

  // ──────────────── Attack #10: Double Settlement ────────────────
  /// @notice Same route cannot be settled twice through different fills.
  function testAttack_DoubleSettlementBlocked() public {
    vm.prank(alice);
    vault.deposit(100_000, alice);

    bytes32 routeId = keccak256("double-settle-route");
    bytes32 fillId = keccak256("double-settle-fill");

    vault.reserveLiquidity(routeId, 10_000, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, 10_000);
    asset.mint(address(vault), 100); // fee income arrives via CCIP
    vault.reconcileSettlementSuccess(fillId, 10_000, 100);

    // Route is now SettledSuccess, cannot be re-reserved
    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reserveLiquidity(routeId, 5_000, uint64(block.timestamp + 2 hours));

    // Cannot execute fill on settled route
    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.executeFill(routeId, keccak256("new-fill"), 5_000);
  }

  // ──────────────── Attack #9: Over-Withdrawal ────────────────
  /// @notice Cannot withdraw more than available free liquidity.
  function testAttack_OverWithdrawalReverts() public {
    vm.prank(alice);
    vault.deposit(10_000, alice);

    vault.reserveLiquidity(keccak256("reserve-route"), 8_000, uint64(block.timestamp + 1 hours));

    // Only 2000 free, try to withdraw 5000
    vm.prank(alice);
    vm.expectRevert(LaneVault4626.InsufficientFreeLiquidity.selector);
    vault.withdraw(5_000, alice, alice);
  }

  // ──────────────── Attack #5: Rapid Cycling ────────────────
  /// @notice 50 deposit/withdraw cycles should not drift accounting.
  function testAttack_RapidCyclingNoAccountingDrift() public {
    for (uint256 i = 0; i < 50; i++) {
      vm.prank(alice);
      vault.deposit(1_000, alice);

      vm.prank(alice);
      vault.withdraw(1_000, alice, alice);
    }

    assertEq(vault.totalAssets(), 0, "total assets must be zero after equal deposit/withdraw cycles");
    assertEq(vault.freeLiquidityAssets(), 0, "free liquidity must be zero");
    assertEq(vault.totalSupply(), 0, "total supply must be zero");
  }

  function _mintAndApprove(address account, uint256 amount) internal {
    asset.mint(account, amount);
    vm.prank(account);
    asset.approve(address(vault), type(uint256).max);
  }
}
