// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LaneVault4626} from "../src/LaneVault4626.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Scan Campaign Findings — LaneVault4626
/// @notice Reproduces audit observations discovered during the March 2026 scan campaign.
contract ScanCampaignLaneVaultFindingsTest is Test {
  MockERC20 internal asset;
  LaneVault4626 internal vault;

  address internal lp = makeAddr("lp");

  function setUp() public {
    asset = new MockERC20("Mock Asset", "mAST");
    vault = new LaneVault4626(asset, "Lane Vault LP", "lvLP", 1 days, address(this));

    asset.mint(lp, 10_000);
    vm.prank(lp);
    asset.approve(address(vault), type(uint256).max);

    vm.prank(lp);
    vault.deposit(10_000, lp);
  }

  function testFix_maxWithdrawAndMaxRedeemReturnZeroWhileGlobalPaused() public {
    vault.setPauseFlags(true, false, false);

    assertEq(vault.maxWithdraw(lp), 0, "global pause should advertise zero withdrawable assets");
    assertEq(vault.maxRedeem(lp), 0, "global pause should advertise zero redeemable shares");
  }
}
