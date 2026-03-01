// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { LaneQueueManager } from "../src/LaneQueueManager.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract LaneVault4626FuzzTest is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal carol = makeAddr("carol");
  address internal receiverA = makeAddr("receiver-a");
  address internal receiverB = makeAddr("receiver-b");
  address internal receiverC = makeAddr("receiver-c");

  function setUp() public {
    asset = new MockERC20("Mock Asset", "mAST");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    _mintAndApprove(alice, 1_000_000);
    _mintAndApprove(bob, 1_000_000);
    _mintAndApprove(carol, 1_000_000);
  }

  function testFuzzShareConservationAcrossQueueAndProcessing(
    uint96 depositAlice,
    uint96 depositBob,
    uint96 requestAlice,
    uint96 requestBob
  ) public {
    uint256 aliceAssets = bound(uint256(depositAlice), 1_000, 300_000);
    uint256 bobAssets = bound(uint256(depositBob), 1_000, 300_000);

    vm.prank(alice);
    vault.deposit(aliceAssets, alice);

    vm.prank(bob);
    vault.deposit(bobAssets, bob);

    _assertShareConservation();

    uint256 aliceShares = vault.balanceOf(alice);
    uint256 bobShares = vault.balanceOf(bob);

    uint256 aliceRequest = bound(uint256(requestAlice), 1, aliceShares);
    uint256 bobRequest = bound(uint256(requestBob), 1, bobShares);

    vm.prank(alice);
    vault.requestRedeem(aliceRequest, receiverA, alice);

    vm.prank(bob);
    vault.requestRedeem(bobRequest, receiverB, bob);

    _assertShareConservation();

    uint256 processed = vault.processRedeemQueue(2);
    assertEq(processed, 2, "both queued requests should process");

    _assertShareConservation();
  }

  function testFuzzFifoFairnessForQueuedRedeems(
    uint96 depositA,
    uint96 depositB,
    uint96 depositC,
    uint96 sharesA,
    uint96 sharesB,
    uint96 sharesC
  ) public {
    uint256 assetsA = bound(uint256(depositA), 1_000, 200_000);
    uint256 assetsB = bound(uint256(depositB), 1_000, 200_000);
    uint256 assetsC = bound(uint256(depositC), 1_000, 200_000);

    vm.prank(alice);
    vault.deposit(assetsA, alice);
    vm.prank(bob);
    vault.deposit(assetsB, bob);
    vm.prank(carol);
    vault.deposit(assetsC, carol);

    uint256 redeemA = bound(uint256(sharesA), 1, vault.balanceOf(alice));
    uint256 redeemB = bound(uint256(sharesB), 1, vault.balanceOf(bob));
    uint256 redeemC = bound(uint256(sharesC), 1, vault.balanceOf(carol));

    vm.prank(alice);
    uint256 requestA = vault.requestRedeem(redeemA, receiverA, alice);
    vm.prank(bob);
    uint256 requestB = vault.requestRedeem(redeemB, receiverB, bob);
    vm.prank(carol);
    uint256 requestC = vault.requestRedeem(redeemC, receiverC, carol);

    LaneQueueManager queue = vault.queueManager();

    {
      (bool exists, LaneQueueManager.RedeemRequest memory nextReq) = queue.peek();
      assertTrue(exists, "queue should have first request");
      assertEq(nextReq.requestId, requestA, "FIFO request id mismatch (1)");
      assertEq(nextReq.owner, alice, "FIFO owner mismatch (1)");
    }

    vault.processRedeemQueue(1);

    {
      (bool exists, LaneQueueManager.RedeemRequest memory nextReq) = queue.peek();
      assertTrue(exists, "queue should have second request");
      assertEq(nextReq.requestId, requestB, "FIFO request id mismatch (2)");
      assertEq(nextReq.owner, bob, "FIFO owner mismatch (2)");
    }

    vault.processRedeemQueue(1);

    {
      (bool exists, LaneQueueManager.RedeemRequest memory nextReq) = queue.peek();
      assertTrue(exists, "queue should have third request");
      assertEq(nextReq.requestId, requestC, "FIFO request id mismatch (3)");
      assertEq(nextReq.owner, carol, "FIFO owner mismatch (3)");
    }

    vault.processRedeemQueue(1);
    assertEq(queue.pendingCount(), 0, "queue should be empty after FIFO processing");
  }

  function testFuzzNoDoubleSettleAfterTerminalTransition(uint96 depositAmount, uint96 reserveAmount, uint96 feeIncome)
    public
  {
    uint256 depositAssets = bound(uint256(depositAmount), 50_000, 300_000);

    vm.prank(alice);
    vault.deposit(depositAssets, alice);

    vault.setPolicy(1_000, 9_000, 2_000, 0, 1_000);
    vault.setSettlementAdapter(address(this));

    uint256 reserveAssets = bound(uint256(reserveAmount), 1_000, depositAssets / 2);
    bytes32 routeId = keccak256(abi.encode("route-no-double", depositAssets, reserveAssets));
    bytes32 fillId = keccak256(abi.encode("fill-no-double", reserveAssets));

    vault.reserveLiquidity(routeId, reserveAssets, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, reserveAssets);

    uint256 feeAssets = bound(uint256(feeIncome), 0, reserveAssets / 10);
    if (feeAssets > 0) asset.mint(address(vault), feeAssets); // fee income arrives via CCIP
    vault.reconcileSettlementSuccess(fillId, reserveAssets, feeAssets);

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reconcileSettlementSuccess(fillId, reserveAssets, feeAssets);

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.reconcileSettlementLoss(fillId, reserveAssets, reserveAssets - 1);

    vm.expectRevert(LaneVault4626.InvalidTransition.selector);
    vault.releaseReservation(routeId);
  }

  function testFuzzPauseAndRoleSafety(address attacker, uint96 depositAmount) public {
    vm.assume(attacker != address(0));
    vm.assume(attacker != address(this));
    vm.assume(attacker != alice);
    vm.assume(attacker != bob);

    uint256 depositAssets = bound(uint256(depositAmount), 5_000, 100_000);

    vm.prank(alice);
    vault.deposit(depositAssets, alice);

    vm.prank(attacker);
    vm.expectRevert();
    vault.setPauseFlags(true, false, false);

    vm.prank(attacker);
    vm.expectRevert();
    vault.reserveLiquidity(keccak256("attacker-route"), 1_000, uint64(block.timestamp + 1 hours));

    vm.prank(attacker);
    vm.expectRevert();
    vault.processRedeemQueue(1);

    bytes32 routeId = keccak256("pause-route-1");
    bytes32 routeId2 = keccak256("pause-route-2");
    bytes32 fillId = keccak256("pause-fill");

    vault.reserveLiquidity(routeId, 1_000, uint64(block.timestamp + 1 hours));

    vault.setPauseFlags(true, true, true);

    vm.prank(alice);
    vm.expectRevert(LaneVault4626.GlobalPaused.selector);
    vault.deposit(1, alice);

    vm.expectRevert(LaneVault4626.GlobalPaused.selector);
    vault.releaseReservation(routeId);

    vault.setPauseFlags(false, true, false);

    vm.prank(alice);
    vm.expectRevert(LaneVault4626.DepositPaused.selector);
    vault.deposit(1, alice);

    vm.prank(alice);
    vm.expectRevert(LaneVault4626.DepositPaused.selector);
    vault.mint(1, alice);

    // Reserve lifecycle is still active when only deposit pause is enabled.
    vault.releaseReservation(routeId);
    vault.reserveLiquidity(routeId2, 1_000, uint64(block.timestamp + 1 hours));

    vault.setPauseFlags(false, false, true);

    vm.expectRevert(LaneVault4626.ReservePaused.selector);
    vault.reserveLiquidity(keccak256("pause-route-3"), 1_000, uint64(block.timestamp + 1 hours));

    vm.expectRevert(LaneVault4626.ReservePaused.selector);
    vault.releaseReservation(routeId2);

    vm.expectRevert(LaneVault4626.ReservePaused.selector);
    vault.executeFill(routeId2, fillId, 1_000);
  }

  function _assertShareConservation() internal {
    uint256 observed =
      vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(carol) + vault.balanceOf(address(vault));
    assertEq(vault.totalSupply(), observed, "share conservation breached");
  }

  function _mintAndApprove(address account, uint256 amount) internal {
    asset.mint(account, amount);
    vm.prank(account);
    asset.approve(address(vault), type(uint256).max);
  }
}
