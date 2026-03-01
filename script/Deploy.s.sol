// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { LaneVault4626 } from "../src/LaneVault4626.sol";
import { LaneSettlementAdapter, ILaneVaultSettlement } from "../src/LaneSettlementAdapter.sol";

/// @title DeployLaneVault
/// @notice Deploys LaneVault4626 + LaneSettlementAdapter in paused state.
/// @dev
///   Required env vars:
///     ASSET_ADDRESS         — ERC-20 token used as vault underlying (e.g. LINK)
///     CCIP_ROUTER           — Chainlink CCIP Router address on the destination chain
///     INITIAL_ADMIN         — Address that receives DEFAULT_ADMIN + GOVERNANCE + OPS + PAUSER
///     DEFAULT_ADMIN_DELAY   — Timelock delay in seconds for admin role transfer (e.g. 172800 = 2 days)
///
///   The script:
///     1. Deploys LaneVault4626 with the provided asset and admin
///     2. Deploys LaneSettlementAdapter wired to the vault and CCIP router
///     3. Registers the adapter as the vault's settlement adapter (grants SETTLEMENT_ROLE)
///     4. Pauses all vault operations (global + deposit + reserve)
///
///   Usage (dry run — no broadcast):
///     forge script script/Deploy.s.sol --rpc-url $RPC_URL --sender $INITIAL_ADMIN
///
///   Usage (broadcast — signs and sends):
///     forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
///
///   Usage (Ledger / multisig — unsigned):
///     forge script script/Deploy.s.sol --rpc-url $RPC_URL --slow
///     (then submit the unsigned tx bundle to Safe / multisig)
contract DeployLaneVault is Script {
  function run() external {
    address asset = vm.envAddress("ASSET_ADDRESS");
    address ccipRouter = vm.envAddress("CCIP_ROUTER");
    address initialAdmin = vm.envAddress("INITIAL_ADMIN");
    uint48 defaultAdminDelay = uint48(vm.envUint("DEFAULT_ADMIN_DELAY"));

    console.log("=== LaneVault4626 Paused Deploy ===");
    console.log("Asset:", asset);
    console.log("CCIP Router:", ccipRouter);
    console.log("Initial Admin:", initialAdmin);
    console.log("Admin Delay (s):", uint256(defaultAdminDelay));

    vm.startBroadcast(initialAdmin);

    // 1. Deploy vault
    LaneVault4626 vault = new LaneVault4626(IERC20(asset), "Lane Vault LP", "lvLP", defaultAdminDelay, initialAdmin);
    console.log("Vault deployed:", address(vault));

    // 2. Deploy CCIP settlement adapter
    LaneSettlementAdapter adapter = new LaneSettlementAdapter(ccipRouter, ILaneVaultSettlement(address(vault)));
    console.log("Adapter deployed:", address(adapter));

    // 3. Wire adapter to vault (grants SETTLEMENT_ROLE to adapter)
    vault.setSettlementAdapter(address(adapter));
    console.log("Adapter registered as settlement adapter");

    // 4. Pause everything — no operations until explicit unpause
    vault.setPauseFlags(true, true, true);
    console.log("Vault paused: global=true, deposit=true, reserve=true");

    vm.stopBroadcast();

    // Verification summary
    console.log("");
    console.log("=== Post-Deploy Verification ===");
    console.log("vault.globalPaused():", vault.globalPaused());
    console.log("vault.depositPaused():", vault.depositPaused());
    console.log("vault.reservePaused():", vault.reservePaused());
    console.log("vault.settlementAdapter():", vault.settlementAdapter());
  }
}
