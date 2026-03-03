// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { LaneSettlementAdapter, ILaneVaultSettlement } from "../src/LaneSettlementAdapter.sol";

/// @title DeployLaneVaultDemo
/// @notice Deploys MockERC20 + LaneVault4626 + LaneSettlementAdapter for demo/simulation.
///   - Mints 100,000 mock tokens to the deployer
///   - Deposits 50,000 into the vault
///   - Leaves vault UNPAUSED and ready for simulation
contract DeployLaneVaultDemo is Script {
  function run() external {
    address ccipRouter = vm.envAddress("CCIP_ROUTER");
    address initialAdmin = vm.envAddress("INITIAL_ADMIN");

    console.log("=== LaneVault4626 Demo Deploy ===");
    console.log("CCIP Router:", ccipRouter);
    console.log("Initial Admin:", initialAdmin);

    vm.startBroadcast(initialAdmin);

    // 1. Deploy mock token
    MockERC20 token = new MockERC20("Mock LINK", "mLINK");
    console.log("MockERC20 deployed:", address(token));

    // 2. Mint 100,000 tokens to deployer
    token.mint(initialAdmin, 100_000 ether);
    console.log("Minted 100,000 mLINK to deployer");

    // 3. Deploy vault
    LaneVault4626 vault = new LaneVault4626(
      IERC20(address(token)),
      "Lane Vault LP (Demo)",
      "lvLP-demo",
      0,           // no admin delay for demo
      initialAdmin
    );
    console.log("Vault deployed:", address(vault));

    // 4. Deploy adapter
    LaneSettlementAdapter adapter = new LaneSettlementAdapter(
      ccipRouter,
      ILaneVaultSettlement(address(vault))
    );
    console.log("Adapter deployed:", address(adapter));

    // 5. Wire adapter
    vault.setSettlementAdapter(address(adapter));
    console.log("Adapter registered");

    // 6. Deposit 50,000 mLINK into vault
    token.approve(address(vault), 50_000 ether);
    uint256 shares = vault.deposit(50_000 ether, initialAdmin);
    console.log("Deposited 50,000 mLINK, received shares:", shares);

    vm.stopBroadcast();

    // Verification
    console.log("");
    console.log("=== Post-Deploy State ===");
    console.log("vault.totalAssets():", vault.totalAssets());
    console.log("vault.freeLiquidityAssets():", vault.freeLiquidityAssets());
    console.log("vault.globalPaused():", vault.globalPaused());
    console.log("vault.queueManager():", address(vault.queueManager()));
  }
}
