// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { LaneQueueManager } from "../src/LaneQueueManager.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @title LaneVault4626 Enhanced Invariant Tests
/// @notice Tests 6 new invariants from the enhanced SC Auditor methodology
///         using randomized action sequences (same pattern as existing invariant suite).
contract LaneVault4626EnhancedInvariantTest is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal carol = makeAddr("carol");
  address internal dave = makeAddr("dave");
  address internal eve = makeAddr("eve");

  uint256 internal routeNonce;

  // Ghost variables
  uint256 internal ghostTotalFeeIncome;
  uint256 internal ghostTotalLoss;
  uint256 internal ghostSettlements;

  function setUp() public {
    asset = new MockERC20("Mock Asset", "mAST");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    _mintAndApprove(alice, 5_000_000);
    _mintAndApprove(bob, 5_000_000);
    _mintAndApprove(carol, 5_000_000);
    _mintAndApprove(dave, 5_000_000);
    _mintAndApprove(eve, 5_000_000);

    vault.setPolicy(1_000, 9_000, 2_000, 500, 1_000);
    vault.setSettlementAdapter(address(this));
  }

  /// @notice Fuzz invariant test with 48-action sequences covering all vault operations.
  ///         Each action is randomized between: deposit, withdraw, requestRedeem, processQueue,
  ///         reserveAndSettleSuccess, reserveAndSettleLoss.
  function testFuzzInvariant_EnhancedConservation(uint8[48] memory actions, uint96[48] memory amounts) public {
    // Seed initial liquidity to enable all action paths
    vm.prank(alice);
    vault.deposit(500_000, alice);
    vm.prank(bob);
    vault.deposit(300_000, bob);

    for (uint256 i = 0; i < actions.length; i++) {
      uint8 action = uint8(uint256(actions[i]) % 6);

      if (action == 0) {
        _actionDeposit(actions[i], amounts[i]);
      } else if (action == 1) {
        _actionWithdraw(actions[i], amounts[i]);
      } else if (action == 2) {
        _actionRequestRedeem(actions[i], amounts[i]);
      } else if (action == 3) {
        _actionProcessQueue(amounts[i]);
      } else if (action == 4) {
        _actionReserveAndSettleSuccess(amounts[i]);
      } else {
        _actionReserveAndSettleLoss(amounts[i]);
      }

      // ═══ Assert all invariants after every action ═══
      _assertInvariant_SolvencyConservation();
      _assertInvariant_ShareConservation();
      _assertInvariant_QueueCoherence();
      _assertInvariant_FeeAccrualBound();
      _assertInvariant_AssetSufficiency();
      _assertInvariant_AccountingBounds();
    }
  }

  // ═══════════════ INV-SOLVENCY ═══════════════
  function _assertInvariant_SolvencyConservation() internal {
    uint256 free = vault.freeLiquidityAssets();
    uint256 reserved = vault.reservedLiquidityAssets();
    uint256 inFlight = vault.inFlightLiquidityAssets();
    uint256 protocolFees = vault.protocolFeeAccruedAssets();
    uint256 totalAssets = vault.totalAssets();

    // totalAssets = free + reserved + inFlight - protocolFees (or 0 if negative)
    uint256 grossAssets = free + reserved + inFlight;
    uint256 expected = protocolFees >= grossAssets ? 0 : grossAssets - protocolFees;
    assertEq(totalAssets, expected, "INV-SOLVENCY: conservation law violated");
  }

  // ═══════════════ INV-SHARE ═══════════════
  function _assertInvariant_ShareConservation() internal {
    uint256 sumBalances = vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(carol)
      + vault.balanceOf(dave) + vault.balanceOf(eve) + vault.balanceOf(address(vault));

    assertEq(vault.totalSupply(), sumBalances, "INV-SHARE: share conservation violated");
  }

  // ═══════════════ INV-QUEUE ═══════════════
  function _assertInvariant_QueueCoherence() internal {
    LaneQueueManager queue = vault.queueManager();
    uint256 head = queue.headRequestId();
    uint256 tail = queue.tailRequestId();
    uint256 pending = queue.pendingCount();

    if (pending == 0) {
      assertEq(head, 0, "INV-QUEUE: head must be 0 when empty");
      assertEq(tail, 0, "INV-QUEUE: tail must be 0 when empty");
    } else {
      assertGt(head, 0, "INV-QUEUE: head must be > 0 when non-empty");
      assertGe(tail, head, "INV-QUEUE: tail >= head");
      assertEq(pending, tail - head + 1, "INV-QUEUE: pending count mismatch");
    }
  }

  // ═══════════════ INV-FEE ═══════════════
  function _assertInvariant_FeeAccrualBound() internal {
    uint256 protocolFees = vault.protocolFeeAccruedAssets();
    uint256 feeBps = vault.protocolFeeBps();

    if (ghostTotalFeeIncome == 0 || feeBps == 0) return;

    // Max possible protocol fee = ceil(feeBps/10000 * totalFeeIncome)
    uint256 maxProtocolFee = (ghostTotalFeeIncome * feeBps + 9_999) / 10_000;
    assertLe(protocolFees, maxProtocolFee, "INV-FEE: protocol fee exceeds theoretical max");
  }

  // ═══════════════ INV-ASSET ═══════════════
  function _assertInvariant_AssetSufficiency() internal {
    if (vault.totalSupply() == 0) return;

    uint256 sumWithdrawable = vault.previewRedeem(vault.balanceOf(alice))
      + vault.previewRedeem(vault.balanceOf(bob)) + vault.previewRedeem(vault.balanceOf(carol))
      + vault.previewRedeem(vault.balanceOf(dave)) + vault.previewRedeem(vault.balanceOf(eve))
      + vault.previewRedeem(vault.balanceOf(address(vault)));

    // Allow 1 wei rounding tolerance per user
    assertGe(vault.totalAssets() + 6, sumWithdrawable, "INV-ASSET: totalAssets < sum of withdrawable");
  }

  // ═══════════════ INV-ACCOUNTING ═══════════════
  function _assertInvariant_AccountingBounds() internal {
    assertLe(
      vault.badDebtReserveAssets(),
      vault.freeLiquidityAssets(),
      "INV-ACCOUNTING: bad debt reserve > free liquidity"
    );
    assertLe(
      vault.protocolFeeAccruedAssets(),
      vault.freeLiquidityAssets(),
      "INV-ACCOUNTING: protocol fee > free liquidity"
    );
  }

  // ═══════════════ Actions ═══════════════

  function _actionDeposit(uint8 actorSeed, uint96 amount) internal {
    address actor = _actor(actorSeed);
    uint256 bal = asset.balanceOf(actor);
    if (bal == 0) return;

    uint256 assets = bound(uint256(amount), 1, bal > 200_000 ? 200_000 : bal);
    vm.prank(actor);
    vault.deposit(assets, actor);
  }

  function _actionWithdraw(uint8 actorSeed, uint96 amount) internal {
    address actor = _actor(actorSeed);
    uint256 maxW = vault.maxWithdraw(actor);
    if (maxW == 0) return;

    uint256 assets = bound(uint256(amount), 1, maxW);
    vm.prank(actor);
    vault.withdraw(assets, actor, actor);
  }

  function _actionRequestRedeem(uint8 actorSeed, uint96 shares) internal {
    address actor = _actor(actorSeed);
    uint256 bal = vault.balanceOf(actor);
    if (bal == 0) return;

    uint256 redeemShares = bound(uint256(shares), 1, bal);
    vm.prank(actor);
    vault.requestRedeem(redeemShares, actor, actor);
  }

  function _actionProcessQueue(uint96 maxRequests) internal {
    uint256 requests = bound(uint256(maxRequests), 1, 5);
    vault.processRedeemQueue(requests);
  }

  function _actionReserveAndSettleSuccess(uint96 reserveAmount) internal {
    uint256 available = vault.availableFreeLiquidityForLP();
    if (available == 0) return;

    uint256 amount = bound(uint256(reserveAmount), 1, available);

    bytes32 routeId = keccak256(abi.encode("enh-route", routeNonce));
    bytes32 fillId = keccak256(abi.encode("enh-fill", routeNonce));
    routeNonce += 1;

    // Small fee income (0-5% of principal)
    uint256 feeIncome = amount / 50;

    try vault.reserveLiquidity(routeId, amount, uint64(block.timestamp + 1 hours)) {
      vault.executeFill(routeId, fillId, amount);
      vault.reconcileSettlementSuccess(fillId, amount, feeIncome);
      ghostTotalFeeIncome += feeIncome;
      ghostSettlements += 1;
    } catch {}
  }

  function _actionReserveAndSettleLoss(uint96 reserveAmount) internal {
    uint256 available = vault.availableFreeLiquidityForLP();
    if (available < 100) return;

    uint256 amount = bound(uint256(reserveAmount), 100, available);
    // Recover 80-100% of principal
    uint256 recovered = amount * 80 / 100;

    bytes32 routeId = keccak256(abi.encode("loss-route", routeNonce));
    bytes32 fillId = keccak256(abi.encode("loss-fill", routeNonce));
    routeNonce += 1;

    try vault.reserveLiquidity(routeId, amount, uint64(block.timestamp + 1 hours)) {
      vault.executeFill(routeId, fillId, amount);
      vault.reconcileSettlementLoss(fillId, amount, recovered);
      ghostTotalLoss += (amount - recovered);
      ghostSettlements += 1;
    } catch {}
  }

  function _actor(uint256 seed) internal view returns (address) {
    uint256 idx = seed % 5;
    if (idx == 0) return alice;
    if (idx == 1) return bob;
    if (idx == 2) return carol;
    if (idx == 3) return dave;
    return eve;
  }

  function _mintAndApprove(address account, uint256 amount) internal {
    asset.mint(account, amount);
    vm.prank(account);
    asset.approve(address(vault), type(uint256).max);
  }
}
