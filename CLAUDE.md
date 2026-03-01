# SDL-CCIP-Bridge -- AI Agent Instructions

> Read this before any task in this repository.

## Project Identity

**SDL CCIP Bridge** is a non-upgradeable ERC-4626 LP vault with Chainlink CCIP settlement for cross-chain bridge liquidity. Part of the Orbital/SDL ecosystem.

## Critical Rules

1. **Solidity version is locked to `0.8.24`** -- never change the pragma
2. **OpenZeppelin version is `5.0.2`** -- do not upgrade without explicit approval
3. **No proxy patterns** -- contracts are immutable by design
4. **All state-mutating functions must have `nonReentrant`** -- no exceptions
5. **Run `forge test -vv` before any commit** -- all 60 tests must pass
6. **Run `forge fmt --check` before any commit** -- formatting must be clean
7. **Never modify `_assertAccountingInvariants()` without adding corresponding test coverage**
8. **Conventional commits:** `feat:`, `fix:`, `docs:`, `chore:`, `test:`

## Architecture

```
src/
  LaneVault4626.sol          -- Core vault (616 LOC): ERC-4626 + 5-bucket accounting
  LaneQueueManager.sol       -- FIFO redemption queue (91 LOC): non-cancelable
  LaneSettlementAdapter.sol  -- CCIP receiver (104 LOC): replay + domain binding
  LaneVaultScaffold.sol      -- Simulation scaffold (227 LOC): not deployed

test/
  LaneVault4626.t.sol                    -- Core vault tests (8)
  LaneVault4626Fuzz.t.sol                -- Fuzz tests (4)
  LaneVault4626Invariant.t.sol           -- State machine invariants (1)
  LaneVault4626.EnhancedInvariants.t.sol -- 6-invariant fuzz (1)
  LaneVault4626.Attacks.t.sol            -- Attack scenarios (14)
  SecurityAudit.Attacks.t.sol            -- E2E security audit attacks (10): ATK-B01 to B10
  LaneSettlementAdapter.t.sol            -- Adapter tests (6)
  LaneVaultScaffold.t.sol                -- Scaffold tests (5)
  DeepAudit.t.sol                        -- Deep audit tests (11)
  mocks/MockERC20.sol                    -- Test mock

script/
  Deploy.s.sol               -- Deployment script (deploys paused)

docs/
  WHITEPAPER.md              -- Technical whitepaper
  AUDIT-REPORT.md            -- Phase 1 audit (9-phase methodology)
  DEEP-AUDIT-REPORT.md       -- Deep re-audit (cross-system)
```

## Key Concepts

- **5 liquidity buckets:** free, reserved, inFlight, badDebtReserve, protocolFee
- **Dual state machines:** Routes (None > Reserved > Filled > Settled) and Fills (None > Executed > Settled)
- **FIFO queue:** Non-cancelable redemption queue, shares escrowed in vault
- **Settlement adapter:** CCIP receiver with 3-layer validation (source allowlist, replay, domain binding)
- **Emergency release:** 72h timelock for stuck fills (GOVERNANCE_ROLE)

## Roles

| Role | Purpose |
|------|---------|
| `DEFAULT_ADMIN_ROLE` | Role management (2-step transfer with timelock) |
| `GOVERNANCE_ROLE` | Policy, adapter config, fee claims, emergency |
| `OPS_ROLE` | Reserve, fill, queue processing |
| `PAUSER_ROLE` | Pause/unpause operations |
| `SETTLEMENT_ROLE` | Settlement only (adapter contract) |

## Commands

```bash
forge build                    # Compile
forge test -vv                 # Run all tests
forge test --fuzz-runs 10000   # Audit-grade fuzz
forge test --gas-report        # Gas analysis
forge fmt --check              # Format check
forge fmt                      # Auto-format
```

## Dependencies

| Package | Version | Source |
|---------|---------|--------|
| OpenZeppelin | 5.0.2 | `lib/openzeppelin-contracts` |
| Chainlink CCIP | 1.6.1 | `lib/chainlink-ccip` |
| Forge Std | latest | `lib/forge-std` |
