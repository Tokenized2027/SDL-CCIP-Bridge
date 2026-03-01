# Layer 7 LP Vault Contracts

Foundry subproject for the Layer 7 CCIP lane vault.

## Scope

This package contains:

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
- `test/LaneVault4626Fuzz.t.sol`: fuzz tests for share conservation, FIFO fairness, settlement isolation.
- `test/LaneVault4626Invariant.t.sol`: invariant tests for state machine conservation.
- `test/LaneVault4626.EnhancedInvariants.t.sol`: 6 enhanced invariants (solvency, share, queue, fee, asset, accounting) with 48-action fuzz sequences.
- `test/LaneVault4626.Attacks.t.sol`: 14 attack scenario tests (donation, reentrancy, replay, inflation, etc.).
- `test/LaneSettlementAdapter.t.sol`: adapter replay/source/payload binding tests.
- `test/LaneVaultScaffold.t.sol`: scaffold parity tests.

## Security Audit

**Full 9-phase audit completed 2026-03-01.** See [`AUDIT-REPORT.md`](./AUDIT-REPORT.md).

- **8 findings:** 2 Medium (1 fixed, 1 acknowledged), 3 Low (all fixed), 3 Info (all acknowledged)
- **39 tests passing** (unit + fuzz + invariant + attack)
- **10,000 fuzz runs**, 480K action sequences, 2.88M invariant assertions
- **Static analysis:** Slither v0.11.5 + Aderyn v0.6.8 (all findings triaged as false positives)
- **Methodology:** Enhanced 9-phase (threat model, manual review, static analysis, fix, invariants, attack scenarios, 10K fuzz, full report)

## Local Commands

```bash
cd contracts/layer7-vault
forge fmt --check
forge test -vv
forge test --fuzz-runs 10000  # full audit-grade run
forge test --gas-report
```

## Cost Note

Contract compilation and tests here are free local compute only.
