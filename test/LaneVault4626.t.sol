// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { LaneQueueManager } from "../src/LaneQueueManager.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract LaneVault4626Test is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal receiver = makeAddr("receiver");

  bytes32 internal constant ROUTE_A = keccak256("route-a");
  bytes32 internal constant ROUTE_B = keccak256("route-b");
  bytes32 internal constant FILL_A = keccak256("fill-a");
  bytes32 internal constant FILL_B = keccak256("fill-b");

  function setUp() public {
    asset = new MockERC20("Mock Asset", "mAST");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    asset.mint(alice, 10_000);
    vm.prank(alice);
    asset.approve(address(vault), type(uint256).max);
  }

  function testTotalAssetsExcludesProtocolFeesImmediately() public {
    vm.prank(alice);
    vault.deposit(1_000, alice);

    vault.setPolicy(1_000, 6_000, 2_000, 500, 1_000);
    vault.setSettlementAdapter(address(this));

    vault.reserveLiquidity(ROUTE_A, 500, uint64(block.timestamp + 1 hours));
    vault.executeFill(ROUTE_A, FILL_A, 500);
    vault.reconcileSettlementSuccess(FILL_A, 500, 100);

    assertEq(vault.protocolFeeAccruedAssets(), 5, "protocol fee accrual mismatch");
    assertEq(vault.totalAssets(), 1_095, "fees must be excluded from LP NAV before claim");

    vault.claimProtocolFees(address(0xBEEF), 5);
    assertEq(vault.totalAssets(), 1_095, "claiming fees should not change LP NAV");
  }

  function testRouteAndFillStateMachinesAreOneWay() public {
    vm.prank(alice);
    vault.deposit(2_000, alice);

    vault.reserveLiquidity(ROUTE_A, 400, uint64(block.timestamp + 1 hours));

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reserveLiquidity(ROUTE_A, 50, uint64(block.timestamp + 2 hours));

    vault.releaseReservation(ROUTE_A);

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.executeFill(ROUTE_A, FILL_A, 400);

    vault.setSettlementAdapter(address(this));
    vault.reserveLiquidity(ROUTE_B, 300, uint64(block.timestamp + 1 hours));
    vault.executeFill(ROUTE_B, FILL_B, 300);

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.executeFill(ROUTE_B, FILL_B, 300);

    vault.reconcileSettlementSuccess(FILL_B, 300, 0);

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reconcileSettlementLoss(FILL_B, 300, 250);

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.releaseReservation(ROUTE_B);
  }

  function testQueueEscrowsSharesAndNoCancelPolicy() public {
    vm.prank(alice);
    vault.deposit(1_000, alice);

    vm.prank(alice);
    uint256 requestId = vault.requestRedeem(400, receiver, alice);

    LaneQueueManager queue = vault.queueManager();

    assertEq(requestId, 1, "request id mismatch");
    assertEq(vault.balanceOf(alice), 600, "owner shares should be escrowed");
    assertEq(vault.balanceOf(address(vault)), 400, "vault should hold escrowed shares");
    assertEq(queue.pendingCount(), 1, "queue pending count mismatch");
    assertEq(vault.queueCancellationPolicy(), "no_cancel_once_enqueued", "queue cancellation policy mismatch");

    (bool ok,) = address(vault).call(abi.encodeWithSignature("cancelRedeem(uint256)", requestId));
    assertFalse(ok, "cancel path should not exist");

    uint256 processed = vault.processRedeemQueue(5);

    assertEq(processed, 1, "processed queue count mismatch");
    assertEq(queue.pendingCount(), 0, "queue should be empty");
    assertEq(vault.balanceOf(address(vault)), 0, "escrowed shares should be burned");
    assertEq(asset.balanceOf(receiver), 400, "receiver payout mismatch");
  }

  function testMaxWithdrawAndRedeemRespectFreeLiquidity() public {
    vm.prank(alice);
    vault.deposit(1_000, alice);

    vault.setPolicy(1_000, 9_000, 2_000, 0, 1_000);
    vault.reserveLiquidity(ROUTE_A, 800, uint64(block.timestamp + 1 hours));

    assertEq(vault.maxWithdraw(alice), 200, "maxWithdraw must be free-liquidity bounded");
    assertEq(vault.maxRedeem(alice), 200, "maxRedeem must be free-liquidity bounded");

    LaneVault4626.PreviewOutcome memory redeemOutcome = vault.previewRedeemOutcome(500);
    assertEq(redeemOutcome.instantAssets, 200, "instant redeem assets mismatch");
    assertEq(redeemOutcome.queuedAssets, 300, "queued redeem assets mismatch");

    LaneVault4626.PreviewOutcome memory withdrawOutcome = vault.previewWithdrawOutcome(350);
    assertEq(withdrawOutcome.instantAssets, 200, "instant withdraw assets mismatch");
    assertEq(withdrawOutcome.queuedAssets, 150, "queued withdraw assets mismatch");
  }

  function testPausePrecedenceAndScopes() public {
    vm.prank(alice);
    vault.deposit(1_000, alice);

    vault.setPauseFlags(true, false, false);

    vm.prank(alice);
    vm.expectRevert(LaneVault4626.GlobalPaused.selector);
    vault.deposit(10, alice);

    vm.prank(alice);
    vm.expectRevert(LaneVault4626.GlobalPaused.selector);
    vault.requestRedeem(50, receiver, alice);

    vm.expectRevert(LaneVault4626.GlobalPaused.selector);
    vault.reserveLiquidity(ROUTE_A, 100, uint64(block.timestamp + 1 hours));

    vault.setPauseFlags(false, true, false);

    vm.prank(alice);
    vm.expectRevert(LaneVault4626.DepositPaused.selector);
    vault.deposit(10, alice);

    vm.prank(alice);
    vm.expectRevert(LaneVault4626.DepositPaused.selector);
    vault.mint(10, alice);

    vault.reserveLiquidity(ROUTE_A, 100, uint64(block.timestamp + 1 hours));

    vault.setPauseFlags(false, false, true);

    vm.expectRevert(LaneVault4626.ReservePaused.selector);
    vault.reserveLiquidity(ROUTE_B, 100, uint64(block.timestamp + 1 hours));

    vm.expectRevert(LaneVault4626.ReservePaused.selector);
    vault.releaseReservation(ROUTE_A);

    vm.expectRevert(LaneVault4626.ReservePaused.selector);
    vault.executeFill(ROUTE_A, FILL_A, 100);
  }

  function testTransferAllowlistExemptionsAreExplicit() public {
    vm.prank(alice);
    vault.deposit(500, alice);

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.TransferNotAllowlisted.selector, alice, bob));
    vault.transfer(bob, 10);

    vm.prank(alice);
    vault.withdraw(100, alice, alice);

    vm.prank(alice);
    vault.requestRedeem(50, receiver, alice);

    uint256 processed = vault.processRedeemQueue(1);
    assertEq(processed, 1, "queue should process escrowed shares");
    assertEq(vault.balanceOf(address(vault)), 0, "vault escrow should be empty after processing");
  }

  function testSettlementRoleAssignedOnlyToCurrentAdapter() public {
    bytes32 settlementRole = vault.SETTLEMENT_ROLE();
    address adapterOne = makeAddr("adapter-one");
    address adapterTwo = makeAddr("adapter-two");

    assertFalse(vault.hasRole(settlementRole, address(this)), "deployer should not have settlement role by default");

    vault.setSettlementAdapter(adapterOne);
    assertTrue(vault.hasRole(settlementRole, adapterOne), "adapter one should have settlement role");
    assertFalse(vault.hasRole(settlementRole, adapterTwo), "adapter two should not have role yet");

    vault.setSettlementAdapter(adapterTwo);
    assertFalse(vault.hasRole(settlementRole, adapterOne), "adapter one role should be revoked");
    assertTrue(vault.hasRole(settlementRole, adapterTwo), "adapter two should have settlement role");
  }

  function testDefaultAdminTransferIsTwoStepWithDelay() public {
    address newAdmin = makeAddr("new-admin");

    vault.beginDefaultAdminTransfer(newAdmin);
    (address pendingAdmin, uint48 schedule) = vault.pendingDefaultAdmin();

    assertEq(pendingAdmin, newAdmin, "pending admin mismatch");
    assertGt(schedule, block.timestamp, "admin transfer schedule must be in the future");

    vm.prank(newAdmin);
    vm.expectRevert();
    vault.acceptDefaultAdminTransfer();

    vm.warp(block.timestamp + vault.defaultAdminDelay() + 1);
    vm.prank(newAdmin);
    vault.acceptDefaultAdminTransfer();

    assertEq(vault.defaultAdmin(), newAdmin, "default admin transfer failed");
  }
}
