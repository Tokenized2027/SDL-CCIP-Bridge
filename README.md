# Layer 7 LP Vault Contracts

Foundry subproject for the Layer 7 CCIP lane vault.

## Scope

This package now contains:

1. `LaneVault4626`: asset-native ERC-4626 vault with queue-based redemptions.
2. `LaneQueueManager`: strict FIFO redemption queue with no-cancel policy.
3. `LaneSettlementAdapter`: CCIP receiver adapter with tuple replay protection and payload domain binding.
4. `LaneVaultScaffold`: parity scaffold that mirrors Python invariant modeling in `platform/intelligence/lp_vault_model.py`.

## Layout

- `src/LaneVault4626.sol`: main on-chain vault logic and liquidity accounting.
- `src/LaneQueueManager.sol`: queue primitive for redemption requests.
- `src/LaneSettlementAdapter.sol`: settlement bridge adapter with source allowlists.
- `src/LaneVaultScaffold.sol`: simulation-oriented parity scaffold.
- `test/LaneVault4626.t.sol`: ERC-4626, queue, pause, role, and state-machine tests.
- `test/LaneSettlementAdapter.t.sol`: adapter replay/source/payload binding tests.
- `test/LaneVaultScaffold.t.sol`: scaffold parity tests.

## Local Commands

```bash
cd contracts/layer7-vault
forge fmt --check
forge test -vv
forge test --gas-report
```

## Cost Note

Contract compilation and tests here are free local compute only.
