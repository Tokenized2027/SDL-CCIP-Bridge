# SDL-CCIP-Bridge -- AI Agent Instructions

> Read this before any task in this repository.

## Project Identity

**SDL CCIP Bridge** is a non-upgradeable ERC-4626 LP vault with Chainlink CCIP settlement for cross-chain bridge liquidity. Part of the Orbital/SDL ecosystem.

## Critical Rules

1. **Solidity version is locked to `0.8.24`** -- never change the pragma
2. **OpenZeppelin version is `5.0.2`** -- do not upgrade without explicit approval
3. **No proxy patterns** -- contracts are immutable by design
4. **All state-mutating functions must have `nonReentrant`** -- no exceptions
5. **Run `forge test -vv` before any commit** -- all 83 tests must pass
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
  AdvancedAudit.t.sol                    -- Advanced edge-case audit (15): ADV-01 to ADV-15
  E2E.t.sol                              -- Full lifecycle E2E tests (8): E2E-01 to E2E-08
  mocks/MockERC20.sol                    -- Test mock

script/
  Deploy.s.sol               -- Deployment script (deploys paused)

workflows/                   -- CRE autonomous monitoring (3 workflows)
  vault-health/              -- 5-bucket monitoring + risk classification
  bridge-ai-advisor/         -- AI policy optimizer (HTTPClient + consensus)
  queue-monitor/             -- FIFO queue + liquidity coverage tracking

scripts/                     -- Orchestration & proof writing
  bridge-unified-cycle.sh    -- Phase 1 + 1.5 + 2 orchestration
  record-bridge-proofs.mjs   -- On-chain proof writes to Sepolia
  composite-bridge-intelligence.mjs -- Cross-workflow correlation

platform/
  bridge_analyze_endpoint.py -- Flask AI analysis server (Claude Haiku)

docs/
  WHITEPAPER.md              -- Technical whitepaper
  AUDIT-REPORT.md            -- Phase 1 audit (9-phase methodology)
  DEEP-AUDIT-REPORT.md       -- Deep re-audit (cross-system)
  CRE-AI-ARCHITECTURE.md     -- CRE & AI architecture (hackathon focus)
  how-it-works.md            -- Plain language vault + CRE guide
  verification.md            -- Trust model + proof verification guide
  demo-video-script.md       -- 2:40 demo video script
  submission.md              -- Hackathon submission
```

## CRE Workflow Rules

9. **Workflow isolation:** each workflow is a standalone CRE project with own `package.json`, `node_modules`, config, and ABIs. No shared state between workflows at runtime.
10. **CRE SDK patterns:** Use `consensusIdenticalAggregation` for all HTTPClient calls. Use `encodeCallMsg` for all EVMClient calls. Use `getNetwork` for chain resolution. Use `CronCapability` for scheduling.
11. **Proof hashes are immutable.** Once a `snapshotHash` is written on-chain, it cannot be altered. The hash encoding must stay consistent across TypeScript and Solidity.
12. **AI analysis costs money.** The Flask endpoint uses Claude Haiku (~$0.001-0.003/call). Every workflow simulation that hits this endpoint costs API credits.
13. **Use Bun for workflows, not npm.** Install deps: `cd workflows/<name>/my-workflow && bun install`
14. **CHAINLINK.md must be updated** if any Chainlink touchpoint changes.

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
