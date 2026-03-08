// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { LaneQueueManager } from "../src/LaneQueueManager.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @title Security Audit Attack Test Suite — Layer7-Vault
/// @notice 10 attack vectors from the E2E smart contract security audit (March 2026).
///         Each test simulates a specific DeFi/bridging attack and verifies the vault defends against it.
contract SecurityAuditAttacksTest is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal alice = makeAddr("alice");
  address internal bob = makeAddr("bob");
  address internal attacker = makeAddr("attacker");
  address internal governance = makeAddr("governance");

  function setUp() public {
    asset = new MockERC20("Mock Asset", "mAST");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    _mintAndApprove(alice, 10_000_000e18);
    _mintAndApprove(bob, 10_000_000e18);
    _mintAndApprove(attacker, 10_000_000e18);

    // Max utilization 90%, protocol fee 5%, bad debt cut 10%
    vault.setPolicy(1_000, 9_000, 2_000, 500, 1_000);
    vault.setSettlementAdapter(address(this));
    vault.grantRole(vault.GOVERNANCE_ROLE(), governance);
  }

  // ──────────────── ATK-B01: Flash Loan Share Price Manipulation ────────────────
  /// @notice Flash loan deposit + large donation should NOT inflate share price.
  ///         Virtual accounting (freeLiquidityAssets) is independent of balanceOf.
  function test_ATK_B01_FlashLoanSharePriceManipulation() public {
    // Alice deposits normally
    vm.prank(alice);
    vault.deposit(100_000e18, alice);

    uint256 sharePriceBefore = vault.previewRedeem(1e18);

    // Attacker: deposit large amount, donate directly, attempt to redeem at inflated price
    vm.startPrank(attacker);
    vault.deposit(1_000_000e18, attacker);
    // Direct donation bypasses freeLiquidityAssets tracking
    asset.transfer(address(vault), 5_000_000e18);
    vm.stopPrank();

    uint256 sharePriceAfter = vault.previewRedeem(1e18);

    // Share price only changes from the attacker's deposit (proportional), NOT from donation
    // The key point: donation tokens don't enter freeLiquidityAssets, so totalAssets() is unaffected
    assertEq(sharePriceBefore, sharePriceAfter, "ATK-B01: donation must not inflate share price");
  }

  // ──────────────── ATK-B02: Settlement Fee Overflow ────────────────
  /// @notice Settlement with netFeeIncome = type(uint256).max must revert (BalanceDeficit).
  function test_ATK_B02_SettlementFeeOverflow() public {
    vm.prank(alice);
    vault.deposit(100_000e18, alice);

    bytes32 routeId = keccak256("atk-b02-route");
    bytes32 fillId = keccak256("atk-b02-fill");
    uint256 amount = 10_000e18;

    vault.reserveLiquidity(routeId, amount, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, amount);

    // Attempt settlement with absurd fee income — should revert because actual token balance
    // can't possibly be >= free + reserved + inFlight + type(uint256).max
    vm.expectRevert();
    vault.reconcileSettlementSuccess(fillId, amount, type(uint256).max);
  }

  // ──────────────── ATK-B03: Cross-Chain Replay via Different Vault ────────────────
  /// @notice Settlement for a fillId that doesn't exist in THIS vault must revert.
  function test_ATK_B03_CrossChainReplayDifferentVault() public {
    vm.prank(alice);
    vault.deposit(100_000e18, alice);

    // Fill doesn't exist in this vault
    bytes32 fakeFillId = keccak256("fill-from-another-vault");

    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.InvalidTransition.selector));
    vault.reconcileSettlementSuccess(fakeFillId, 10_000e18, 500e18);
  }

  // ──────────────── ATK-B04: Emergency Release Before Timelock ────────────────
  /// @notice Emergency release should revert if called before the delay has elapsed.
  function test_ATK_B04_EmergencyReleaseBeforeTimelock() public {
    vm.prank(alice);
    vault.deposit(100_000e18, alice);

    bytes32 routeId = keccak256("atk-b04-route");
    bytes32 fillId = keccak256("atk-b04-fill");
    uint256 amount = 10_000e18;

    vault.reserveLiquidity(routeId, amount, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, amount);

    // Try emergency release immediately — should fail (3 day default delay)
    vm.prank(governance);
    vm.expectRevert(
      abi.encodeWithSelector(LaneVault4626.EmergencyReleaseNotReady.selector, fillId, block.timestamp + 3 days)
    );
    vault.emergencyReleaseFill(fillId, 0);
  }

  // ──────────────── ATK-B05: Settlement After Emergency Release ────────────────
  /// @notice Once a fill is emergency released (SettledLoss), normal settlement must revert.
  function test_ATK_B05_SettlementAfterEmergencyRelease() public {
    vm.prank(alice);
    vault.deposit(100_000e18, alice);

    bytes32 routeId = keccak256("atk-b05-route");
    bytes32 fillId = keccak256("atk-b05-fill");
    uint256 amount = 10_000e18;

    vault.reserveLiquidity(routeId, amount, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, amount);

    // Fast forward past emergency delay
    vm.warp(block.timestamp + 4 days);

    vm.prank(governance);
    vault.emergencyReleaseFill(fillId, 0);

    // Now try normal settlement — fill is already SettledLoss
    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.InvalidTransition.selector));
    vault.reconcileSettlementSuccess(fillId, amount, 500e18);
  }

  // ──────────────── ATK-B06: Queue Grief — 1000 Dust Requests ────────────────
  /// @notice Processing 1000 small queue entries must not exceed block gas limit.
  function test_ATK_B06_QueueGriefDustRequests() public {
    // Alice deposits enough to cover all requests
    vm.prank(alice);
    vault.deposit(1_000_000e18, alice);

    // Attacker creates 1000 tiny redeem requests
    vm.startPrank(attacker);
    vault.deposit(10_000e18, attacker);
    uint256 attackerShares = vault.balanceOf(attacker);
    uint256 dustAmount = attackerShares / 1000;
    require(dustAmount > 0, "dust too small");

    // Allowlist attacker for transfer
    vm.stopPrank();
    vault.setTransferAllowlisted(attacker, true);

    vm.startPrank(attacker);
    for (uint256 i = 0; i < 1000; i++) {
      if (vault.balanceOf(attacker) < dustAmount) break;
      vault.requestRedeem(dustAmount, attacker, attacker);
    }
    vm.stopPrank();

    // Process all 1000 — measure gas
    uint256 gasBefore = gasleft();
    vault.processRedeemQueue(1000);
    uint256 gasUsed = gasBefore - gasleft();

    // Must be under 30M gas (block limit)
    assertLt(gasUsed, 30_000_000, "ATK-B06: queue processing exceeds block gas limit");
  }

  // ──────────────── ATK-B07: Concurrent Reserve to Exceed Utilization Cap ────────────────
  /// @notice Two reserve calls that individually pass but together exceed cap — second must revert.
  function test_ATK_B07_ConcurrentReserveExceedsUtilization() public {
    vm.prank(alice);
    vault.deposit(100_000e18, alice);

    uint256 totalManagedAssets = vault.totalAssets();
    // With 90% max utilization, max reservable ≈ 90,000
    // NOTE: utilization check uses integer division which rounds down,
    //       so we need enough overshoot to cross the threshold after rounding.
    uint256 firstReserve = (totalManagedAssets * 4500) / 10_000; // 45%
    uint256 secondReserve = (totalManagedAssets * 4600) / 10_000; // 46% — total = 91%

    bytes32 routeId1 = keccak256("atk-b07-route-1");
    bytes32 routeId2 = keccak256("atk-b07-route-2");

    // First reserve passes (45% < 90% cap)
    vault.reserveLiquidity(routeId1, firstReserve, uint64(block.timestamp + 1 hours));

    // Second reserve pushes to 91% utilization — exceeds 90% cap
    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.UtilizationCapExceeded.selector));
    vault.reserveLiquidity(routeId2, secondReserve, uint64(block.timestamp + 1 hours));
  }

  // ──────────────── ATK-B08: Protocol Fee Exceeding Free Liquidity ────────────────
  /// @notice Protocol fees must never exceed free liquidity (invariant check).
  function test_ATK_B08_ProtocolFeeExceedsFree() public {
    vm.prank(alice);
    vault.deposit(100_000e18, alice);

    bytes32 routeId = keccak256("atk-b08-route");
    bytes32 fillId = keccak256("atk-b08-fill");
    uint256 amount = 50_000e18;

    vault.reserveLiquidity(routeId, amount, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, amount);

    // Provide tokens for settlement fee
    uint256 feeAmount = 5_000e18;
    asset.mint(address(vault), feeAmount);

    // Settle with fee
    vault.reconcileSettlementSuccess(fillId, amount, feeAmount);

    // Verify invariant: protocolFeeAccruedAssets <= freeLiquidityAssets
    assertLe(
      vault.protocolFeeAccruedAssets(), vault.freeLiquidityAssets(), "ATK-B08: protocol fees exceed free liquidity"
    );

    // Try claiming more than accrued — should revert
    uint256 accrued = vault.protocolFeeAccruedAssets();
    if (accrued > 0) {
      vm.prank(governance);
      vm.expectRevert(abi.encodeWithSelector(LaneVault4626.InvalidAmount.selector));
      vault.claimProtocolFees(governance, accrued + 1);
    }
  }

  // ──────────────── ATK-B09: Settlement with Wrong Principal ────────────────
  /// @notice Settlement must verify principal matches the fill amount exactly.
  function test_ATK_B09_SettlementWrongPrincipal() public {
    vm.prank(alice);
    vault.deposit(100_000e18, alice);

    bytes32 routeId = keccak256("atk-b09-route");
    bytes32 fillId = keccak256("atk-b09-fill");
    uint256 amount = 10_000e18;

    vault.reserveLiquidity(routeId, amount, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId, fillId, amount);

    // Try settlement with wrong principal amount
    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.InvalidTransition.selector));
    vault.reconcileSettlementSuccess(fillId, amount + 1, 500e18);

    // Also try loss settlement with wrong principal
    vm.expectRevert(abi.encodeWithSelector(LaneVault4626.InvalidTransition.selector));
    vault.reconcileSettlementLoss(fillId, amount - 1, 5_000e18);
  }

  // ──────────────── ATK-B10: Balance Deficit Edge Case ────────────────
  /// @notice After accumulated bad debt absorption, verify balance check still correct.
  ///         badDebtReserveAssets is a SUB-allocation of freeLiquidityAssets, so
  ///         the balance check (free + reserved + inFlight) already covers it.
  function test_ATK_B10_BalanceDeficitAfterBadDebtAbsorption() public {
    vm.prank(alice);
    vault.deposit(100_000e18, alice);

    // Cycle 1: settlement success — builds up bad debt reserve
    bytes32 routeId1 = keccak256("atk-b10-route-1");
    bytes32 fillId1 = keccak256("atk-b10-fill-1");
    vault.reserveLiquidity(routeId1, 20_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId1, fillId1, 20_000e18);
    asset.mint(address(vault), 2_000e18); // fee income tokens
    vault.reconcileSettlementSuccess(fillId1, 20_000e18, 2_000e18);

    uint256 badDebtBefore = vault.badDebtReserveAssets();
    assertGt(badDebtBefore, 0, "Should have bad debt reserve from fee");

    // Cycle 2: settlement LOSS — consumes bad debt reserve
    bytes32 routeId2 = keccak256("atk-b10-route-2");
    bytes32 fillId2 = keccak256("atk-b10-fill-2");
    vault.reserveLiquidity(routeId2, 15_000e18, uint64(block.timestamp + 1 hours));
    vault.executeFill(routeId2, fillId2, 15_000e18);
    vault.reconcileSettlementLoss(fillId2, 15_000e18, 14_500e18); // 500 loss

    // Verify accounting is still consistent
    uint256 free = vault.freeLiquidityAssets();
    uint256 reserved = vault.reservedLiquidityAssets();
    uint256 inFlight = vault.inFlightLiquidityAssets();
    uint256 badDebt = vault.badDebtReserveAssets();
    uint256 protocolFee = vault.protocolFeeAccruedAssets();
    uint256 actualBalance = asset.balanceOf(address(vault));

    // Core invariant: actual balance >= free + reserved + inFlight
    assertGe(actualBalance, free + reserved + inFlight, "ATK-B10: balance deficit after bad debt absorption");
    // Sub-allocation invariants
    assertLe(badDebt, free, "ATK-B10: bad debt exceeds free liquidity post-loss");
    assertLe(protocolFee, free, "ATK-B10: protocol fee exceeds free liquidity post-loss");
  }

  // ──────────────── Helpers ────────────────

  function _mintAndApprove(address user, uint256 amount) internal {
    asset.mint(user, amount);
    vm.prank(user);
    asset.approve(address(vault), type(uint256).max);
  }
}
