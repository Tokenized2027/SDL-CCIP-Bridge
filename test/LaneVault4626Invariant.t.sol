// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { LaneQueueManager } from "../src/LaneQueueManager.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract LaneVault4626InvariantTest is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal carol = makeAddr("carol");

  uint256 internal routeNonce;

  function setUp() public {
    asset = new MockERC20("Mock Asset", "mAST");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    _mintAndApprove(alice, 1_000_000);
    _mintAndApprove(bob, 1_000_000);
    _mintAndApprove(carol, 1_000_000);

    vault.setPolicy(1_000, 9_000, 2_000, 0, 1_000);
    vault.setSettlementAdapter(address(this));
  }

  function testFuzzInvariant_StateMachineConservation(uint8[32] memory actions, uint96[32] memory amounts) public {
    for (uint256 i = 0; i < actions.length; i++) {
      uint8 action = uint8(uint256(actions[i]) % 4);

      if (action == 0) {
        _actionDeposit(actions[i], amounts[i]);
      } else if (action == 1) {
        _actionRequestRedeem(actions[i], amounts[i]);
      } else if (action == 2) {
        _actionProcessQueue(amounts[i]);
      } else {
        _actionReserveExecuteSettle(amounts[i]);
      }

      _assertCoreInvariants();
    }
  }

  function _actionDeposit(uint8 actorSeed, uint96 amount) internal {
    address actor = _actor(actorSeed);
    uint256 bal = asset.balanceOf(actor);
    if (bal == 0) return;

    uint256 assets = bound(uint256(amount), 1, bal);

    vm.prank(actor);
    vault.deposit(assets, actor);
  }

  function _actionRequestRedeem(uint8 actorSeed, uint96 shares) internal {
    address actor = _actor(actorSeed);
    uint256 bal = vault.balanceOf(actor);
    if (bal == 0) return;

    uint256 requestShares = bound(uint256(shares), 1, bal);

    vm.prank(actor);
    vault.requestRedeem(requestShares, actor, actor);
  }

  function _actionProcessQueue(uint96 maxRequests) internal {
    uint256 requests = bound(uint256(maxRequests), 1, 5);
    vault.processRedeemQueue(requests);
  }

  function _actionReserveExecuteSettle(uint96 reserveAmount) internal {
    uint256 available = vault.availableFreeLiquidityForLP();
    if (available == 0) return;

    bytes32 routeId = keccak256(abi.encode("inv-route", routeNonce));
    bytes32 fillId = keccak256(abi.encode("inv-fill", routeNonce));
    routeNonce += 1;

    uint256 assets = bound(uint256(reserveAmount), 1, available);

    try vault.reserveLiquidity(routeId, assets, uint64(block.timestamp + 1 hours)) {
      vault.executeFill(routeId, fillId, assets);
      // Keep fee income at zero in this harness to avoid synthetic asset drifts.
      vault.reconcileSettlementSuccess(fillId, assets, 0);
    } catch { }
  }

  function _assertCoreInvariants() internal {
    _assertShareConservation();
    _assertAccountingBounds();
    _assertQueueIndexCoherence();
  }

  function _assertShareConservation() internal {
    uint256 observed =
      vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(carol) + vault.balanceOf(address(vault));
    assertEq(vault.totalSupply(), observed, "share conservation breached");
  }

  function _assertAccountingBounds() internal {
    assertLe(vault.badDebtReserveAssets(), vault.freeLiquidityAssets(), "bad debt reserve exceeded free liquidity");
    assertLe(vault.protocolFeeAccruedAssets(), vault.freeLiquidityAssets(), "protocol fee exceeded free liquidity");
  }

  function _assertQueueIndexCoherence() internal {
    LaneQueueManager queue = vault.queueManager();
    uint256 pending = queue.pendingCount();
    uint256 head = queue.headRequestId();
    uint256 tail = queue.tailRequestId();

    if (pending == 0) {
      assertEq(head, 0, "head should reset to zero when queue is empty");
      assertEq(tail, 0, "tail should reset to zero when queue is empty");
      return;
    }

    assertGt(head, 0, "head should be non-zero when queue has entries");
    assertGe(tail, head, "tail should not be behind head");
    assertEq(pending, tail - head + 1, "pending count arithmetic mismatch");
  }

  function _actor(uint256 seed) internal view returns (address) {
    uint256 idx = seed % 3;
    if (idx == 0) return alice;
    if (idx == 1) return bob;
    return carol;
  }

  function _mintAndApprove(address account, uint256 amount) internal {
    asset.mint(account, amount);
    vm.prank(account);
    asset.approve(address(vault), type(uint256).max);
  }
}
