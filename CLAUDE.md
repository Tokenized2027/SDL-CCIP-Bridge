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
  Deploy.s.sol               -- Production deployment (deploys paused, requires real LINK)
  DeployDemo.s.sol           -- Demo deployment (MockERC20 + vault + adapter + 50k deposit)

workflows/                   -- CRE autonomous monitoring (3 workflows)
  vault-health/              -- 5-bucket monitoring + risk classification
  bridge-ai-advisor/         -- AI policy optimizer (HTTPClient + consensus)
  queue-monitor/             -- FIFO queue + liquidity coverage tracking

scripts/                     -- Orchestration & proof writing
  bridge-unified-cycle.sh    -- Phase 1 + 1.5 + 2 orchestration
  record-bridge-proofs.mjs   -- On-chain proof writes to Sepolia
  composite-bridge-intelligence.mjs -- Cross-workflow correlation
  read-vault-state.sh        -- Read all vault state from Sepolia via cast
  simulate-bridge-lifecycle.sh -- Full bridge lifecycle simulation

platform/
  bridge_analyze_endpoint.py -- Flask AI analysis server (GPT-4o)

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

## Sepolia Deployment (Demo Vault)

| Contract | Address |
|----------|---------|
| MockERC20 (mLINK) | `0xf59f724C38BdDe189DEe900aD05305ca007161ed` |
| Demo Vault | `0x5962FBf9EA3398400869c91f1B39860264d6dB24` |
| Demo Adapter | `0x88D335531431FecEBFF8619AFF0c2F28Fd3477C1` |
| Demo Queue | `0xC40Ad4387B75D5BA8BF90b2ce35Ba0062b53aC9B` |
| SentinelRegistry (shared) | `0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40` |
| Deployer/Owner | `0xB250152756E2d6E3bD237a6875aE5E26e3D3877b` |

State: vault has 50,200 mLINK TVL, one completed bridge lifecycle simulation (reserve + fill + settle), 20 mLINK bad debt reserve, 4 proof hashes on-chain.

## Live CRE Deployments (Ethereum Mainnet)

All 3 workflows registered on the Chainlink Workflow Registry (`0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`).

| Workflow | Workflow ID | Tx Hash |
|----------|-------------|---------|
| vault-health | `004fe882fa92634fcb35f608fa94e76f635fb2f8e867d76328fe69e7f64d71d3` | `0x622162af5e1380dbeb71ec7ae2482e1f3d8e518c1c899bc7b102dc83d3012269` |
| bridge-ai-advisor | `00460bc80aef935e416083628b1f00f82c1014f5dcc4e42f847832da2951911f` | `0xd9a942ffc080d140481e2920921b8e623573cdb528e47d7ce60ebe92cea9512e` |
| queue-monitor | `00f900d3da87de6cb1b4bf3a7be2dd550e090f8bbb6a96841275307d20b61e72` | `0x3e1629cd7401a6086784423118983fe9b31ce5e1f17b4f526a147f89fde94fb5` |

Owner: `0xB250152756E2d6E3bD237a6875aE5E26e3D3877b`. CRE user: `avi@stake.link` (FULL_ACCESS, ROOT).

## CRE Workflow Rules

9. **Workflow isolation:** each workflow is a standalone CRE project with own `package.json`, `node_modules`, config, and ABIs. No shared state between workflows at runtime.
10. **CRE SDK patterns:** Use `consensusIdenticalAggregation` for all HTTPClient calls. Use `encodeCallMsg` for all EVMClient calls. Use `getNetwork` for chain resolution. Use `CronCapability` for scheduling.
11. **Proof hashes are immutable.** Once a `snapshotHash` is written on-chain, it cannot be altered. The hash encoding must stay consistent across TypeScript and Solidity.
12. **AI analysis costs money.** The Flask endpoint uses GPT-4o (~$0.003-0.005/call). Every workflow simulation that hits this endpoint costs API credits.
13. **Use Bun for workflows, not npm.** Install deps: `cd workflows/<name>/my-workflow && bun install`
15. **CRE 15-read limit per workflow.** Each workflow execution gets max 15 EVMClient calls. Vault-health and bridge-ai-advisor are trimmed to 11 reads each (4 buckets + 2 totals + 2 policy + 1 pause + 1 queue + 1 price). Do NOT add reads without removing others.
16. **Testnet chain resolution.** `getNetwork()` requires `isTestnet: true` for testnet chains. All workflows auto-detect via `chainName.includes('testnet')`.
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
