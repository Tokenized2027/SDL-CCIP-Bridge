# CRE & AI Architecture: SDL CCIP Bridge

> Autonomous monitoring, AI-powered policy optimization, and verifiable on-chain proofs for an ERC-4626 bridge vault.

---

## Overview

The SDL CCIP Bridge combines three Chainlink CRE workflows with an AI analysis layer to create an autonomous monitoring system for an ERC-4626 LP vault. Each workflow reads vault state via EVMClient, computes a risk classification, and writes a keccak256 proof hash to a SentinelRegistry contract on Sepolia. A composite intelligence layer then cross-correlates all three workflows to surface ecosystem-level risks invisible to any single monitor.

```
┌─────────────────────────────────────────────────────────────┐
│                    CRE Workflow Layer                        │
│                                                             │
│  ┌──────────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │ Vault Health  │  │ Bridge AI Advisor │  │ Queue Monitor │  │
│  │ (15 min)      │  │ (30 min)          │  │ (15 min)      │  │
│  └──────┬───────┘  └────────┬─────────┘  └──────┬───────┘  │
│         │                   │                    │           │
│         │    EVMClient      │   HTTPClient       │           │
│         │    (vault reads)  │   (AI analysis)    │           │
│         ▼                   ▼                    ▼           │
│  ┌──────────────────────────────────────────────────────┐   │
│  │            SentinelRegistry (Sepolia)                 │   │
│  │     recordHealth(snapshotHash, riskLevel)             │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
               ┌──────────────────────────┐
               │  Composite Intelligence   │
               │  (cross-workflow risks)   │
               └──────────────────────────┘
```

---

## CRE Workflows

### 1. Vault Health Monitor

**Purpose:** Real-time 5-bucket liquidity monitoring with risk classification.

**Schedule:** Every 15 minutes via `CronCapability`

**Data Collected (EVMClient reads):**
| Read | Contract | Purpose |
|------|----------|---------|
| `freeLiquidityAssets()` | LaneVault4626 | Available LP liquidity |
| `reservedLiquidityAssets()` | LaneVault4626 | Locked for pending fills |
| `inFlightLiquidityAssets()` | LaneVault4626 | In CCIP transit |
| `badDebtReserveAssets()` | LaneVault4626 | Loss absorption buffer |
| `protocolFeeAccruedAssets()` | LaneVault4626 | Unclaimed protocol fees |
| `totalAssets()` | LaneVault4626 | ERC-4626 total value |
| `totalSupply()` | LaneVault4626 | Share supply |
| `availableFreeLiquidityForLP()` | LaneVault4626 | Withdrawable by LPs |
| `maxUtilizationBps()` | LaneVault4626 | Policy: utilization cap |
| `badDebtReserveCutBps()` | LaneVault4626 | Policy: reserve contribution |
| `globalPaused()` | LaneVault4626 | Emergency state |
| `pendingCount()` | LaneQueueManager | Redemption queue depth |
| `latestAnswer()` | LINK/USD Feed | Price for TVL calculation |

**Risk Classification Logic:**
```
utilizationBps = (reserved + inFlight) * 10000 / totalAssets
reserveRatio = badDebtReserve / totalAssets
sharePrice = totalAssets / totalSupply

CRITICAL: utilization >= 9000 bps OR reserveRatio < 2% OR queueDepth >= 20
WARNING:  utilization >= 7000 bps OR reserveRatio < 5% OR queueDepth >= 5
OK:       all metrics within bounds
```

**Proof Hash:** `keccak256(abi.encode(timestamp, "vault-health", risk, utilBps, totalAssets, freeLiq, queueDepth, reserveRatio, sharePrice))`

**On-chain Output:** `SentinelRegistry.recordHealth(hash, "vault:ok|warning|critical")`

---

### 2. Bridge AI Advisor

**Purpose:** AI-powered policy optimization using GPT-5.2 via DON consensus.

**Schedule:** Every 30 minutes via `CronCapability`

**Architecture:**
```
CRE Workflow (DON nodes)
    │
    ├─ EVMClient: read vault state (same as vault-health)
    │
    ├─ HTTPClient + consensusIdenticalAggregation:
    │   │
    │   └─ POST /api/cre/analyze-bridge
    │       ├─ Input: vault state metrics
    │       ├─ AI Model: GPT-5.2 (gpt-5.2)
    │       └─ Output: structured JSON recommendation
    │
    └─ EVMClient: write proof hash to SentinelRegistry
```

**Why consensusIdenticalAggregation matters:** All DON nodes independently call the AI endpoint. The aggregation requires every node to receive the same response before accepting it. This prevents any single node from injecting false AI recommendations. The AI endpoint is engineered for deterministic output (structured JSON with hash-seeded consistency).

**AI Analysis Endpoint (`platform/bridge_analyze_endpoint.py`):**
- Flask server with `X-CRE-Secret` authentication
- Calls GPT-5.2 with structured prompt containing all vault metrics
- Returns deterministic JSON: `{ risk, recommendation, suggestedActions, policyAdjustments, confidence, reasoning }`
- Policy adjustments: `maxUtilizationBps`, `badDebtReserveCutBps`, `targetHotReserveBps`
- Heuristic fallback when API key is unavailable
- Cost: ~$0.003-0.005 per analysis call

**Example AI Response:**
```json
{
  "risk": "warning",
  "recommendation": "Utilization approaching cap with growing queue",
  "suggestedActions": [
    "Reduce maxUtilizationBps to 5500 to preserve LP exit capacity",
    "Process redemption queue within 2 cycles"
  ],
  "policyAdjustments": {
    "maxUtilizationBps": 5500,
    "badDebtReserveCutBps": null,
    "targetHotReserveBps": 2500
  },
  "confidence": 0.82,
  "reasoning": "High utilization (72%) combined with 7 pending redemptions signals LP liquidity pressure"
}
```

**Proof Hash:** `keccak256(abi.encode(timestamp, "bridge-advisor", risk, utilBps, queueDepth, confidence))`

---

### 3. Queue Monitor

**Purpose:** FIFO redemption queue health tracking and liquidity coverage analysis.

**Schedule:** Every 15 minutes via `CronCapability`

**Data Collected (EVMClient reads):**
| Read | Contract | Purpose |
|------|----------|---------|
| `pendingCount()` | LaneQueueManager | Number of pending redemptions |
| `peek()` | LaneQueueManager | Next request details |
| `headRequestId()` | LaneQueueManager | Queue head pointer |
| `tailRequestId()` | LaneQueueManager | Queue tail pointer |
| `freeLiquidityAssets()` | LaneVault4626 | Available to process queue |
| `totalAssets()` | LaneVault4626 | For coverage ratio |

**Key Metrics:**
- **Queue depth:** number of pending redemption requests
- **Coverage ratio:** `freeLiquidity / totalQueuedAssets` (can the vault fulfill all pending requests?)
- **Wait time estimation:** based on queue position and processing frequency
- **Liquidity crunch detection:** coverage ratio < 1.0 means some LPs will wait

**Risk Classification:**
```
CRITICAL: queueDepth >= 20 OR coverageRatio < 0.5
WARNING:  queueDepth >= 5 OR coverageRatio < 0.8
OK:       queue manageable with adequate coverage
```

**Proof Hash:** `keccak256(abi.encode(timestamp, "queue-monitor", risk, queueDepth, coverageRatio, utilBps))`

---

## Composite Intelligence (Phase 1.5)

After all 3 CRE workflows complete, the composite intelligence script (`scripts/composite-bridge-intelligence.mjs`) cross-correlates data to identify ecosystem-level risks invisible to any single workflow.

**Cross-Correlation Logic:**
```
Signal Escalation Matrix:
─────────────────────────────────────────────
Single workflow warning  → no escalation
Two workflows warning    → composite WARNING
Any workflow critical    → composite WARNING
Two+ workflows critical  → composite CRITICAL
High util + growing queue + AI flagging → CRITICAL (cascade)
─────────────────────────────────────────────
```

**Example cascade detection:**
- Vault Health says: utilization at 75% (warning)
- Queue Monitor says: 8 pending redemptions (warning)
- AI Advisor says: "reduce utilization cap" with 0.85 confidence

No single metric is critical. But the combination signals: LPs are trying to exit, utilization is climbing, and the AI sees the trend. The composite layer escalates to CRITICAL before any individual monitor would.

**Optional AI composite analysis** via `POST /api/cre/analyze-bridge-composite` provides natural-language reasoning about cross-workflow patterns.

---

## On-Chain Proof System

### SentinelRegistry Contract

**Address:** `0x35EFB15A46Fa63262dA1c4D8DE02502Dd8b6E3a5` (Sepolia)

**Interface:**
```solidity
function recordHealth(bytes32 snapshotHash, string calldata riskLevel) external onlyOwner
function latest() external view returns (bytes32 hash, string memory level, uint256 ts)
function count() external view returns (uint256)
function recorded(uint256 index) external view returns (bytes32 hash, string memory level, uint256 ts)
```

**Properties:**
- Ownable2Step (2-step ownership transfer for safety)
- Risk level string capped at 256 bytes
- O(1) access for all read patterns
- Immutable records: once written, a proof cannot be altered

### Hash Encoding Consistency

Proof hashes use `keccak256(abi.encode(...))` with consistent field ordering between:
- CRE workflow TypeScript (using viem's `encodeAbiParameters`)
- Proof recording script (`scripts/record-bridge-proofs.mjs`)
- Solidity verification (matching `abi.encode` layout)

This ensures any party can independently verify that a recorded hash corresponds to a specific set of metrics.

### Prefixed Risk Levels

Each workflow tags its risk level with a source prefix:
```
vault:ok       vault:warning       vault:critical
advisor:ok     advisor:warning     advisor:critical
queue:ok       queue:warning       queue:critical
bridge-composite:ok  bridge-composite:warning  bridge-composite:critical
```

This makes on-chain records self-describing: a `HealthRecorded` event with `riskLevel = "advisor:critical"` is immediately traceable to the bridge-ai-advisor workflow.

---

## CRE/AI Security Audit

A dedicated security review of the CRE and AI components identified and fixed the following issues:

### Findings Summary

| Severity | Count | Fixed |
|----------|-------|-------|
| Critical | 2 | 2/2 |
| High | 2 | 2/2 |
| Medium | 4 | 4/4 |
| Low | 2 | 2/2 |

### Critical Fixes

1. **Hash encoding mismatch (CRE-C01):** The proof recording script used different field ordering than the CRE workflows, producing non-verifiable hashes. Fixed by aligning `encodeAbiParameters` calls to use identical tuple types and field order across all codepaths.

2. **Stale workflow.yaml format (CRE-C02):** Workflow YAML files used a legacy `name/version/description` format instead of the CRE-required `staging-settings/production-settings` structure with `user-workflow` and `workflow-artifacts` blocks. All three workflows were rewritten to the correct format.

### High Fixes

3. **Wrong price feed network (CRE-H01):** Config files referenced the Ethereum mainnet LINK/USD feed address (`0x2c1d...`) for workflows that target Sepolia testnet. All configs updated to Sepolia feed: `0xc59E3633BAAC79493d908e63626716e204A45EdF`.

4. **Missing auth on composite endpoint (CRE-H02):** The `/api/cre/analyze-bridge-composite` Flask route had no `X-CRE-Secret` authentication, allowing unauthenticated callers to trigger AI analysis. Fixed by adding `verify_cre_secret()` check.

### Medium Fixes

5. **Non-atomic state writes (CRE-M01):** Workflow state updates (risk level, metrics, hash) could partially succeed. Fixed with atomic write patterns.

6. **Missing JSON parse error handling (CRE-M02):** Flask endpoint returned 500 on malformed JSON instead of 400. Added explicit try/except with proper error responses.

7. **No CRE_SECRET startup warning (CRE-M03):** Server started silently without authentication when `CRE_SECRET` was unset. Added startup log warning.

8. **Missing global error handler (CRE-M04):** Unhandled exceptions returned raw stack traces. Added Flask error handler returning generic 500 response.

---

## Orchestration

### Phase 1: CRE DON (Autonomous)

All 3 workflows are deployed and active on the Chainlink Workflow Registry (Ethereum mainnet). The DON executes them autonomously via `CronCapability` every 15-30 minutes. No local cron needed for Phase 1.

### Unified Cycle (`scripts/bridge-unified-cycle.sh`)

Runs Phases 1.5 and 2 locally. Phase 1 runs on the CRE DON.

```
Phase 1:    CRE DON (autonomous, on-chain cron)
Phase 1.5:  composite-bridge-intelligence (local, needs cross-workflow data)
Phase 2:    record-bridge-proofs (local, needs owner private key for SentinelRegistry)
```

**Why Phases 1.5 and 2 run locally:**
- CRE workflows are isolated by design (no shared state between workflows at runtime), so composite cross-correlation must happen outside the DON.
- SentinelRegistry uses `onlyOwner` access control. The DON does not hold the owner's private key.

### Proof Recording (`scripts/record-bridge-proofs.mjs`)

Writes verified proof hashes to the SentinelRegistry contract on Sepolia using viem:
- Reads latest workflow outputs
- Computes keccak256 hash with matching field encoding
- Calls `recordHealth(hash, riskLevel)` via signed transaction
- Emits `HealthRecorded` event for dashboard/indexer consumption

---

## Chainlink Products Used

| Product | Component | Usage |
|---------|-----------|-------|
| **CCIP** | LaneSettlementAdapter.sol | Core settlement layer (CCIPReceiver, source allowlist, replay protection, domain binding) |
| **CRE SDK** | All 3 workflow main.ts | Runner, handler, CronCapability, EVMClient, HTTPClient |
| **EVMClient** | All 3 workflows | 15+ on-chain reads per workflow run (vault buckets, policy, queue, pause state) |
| **Data Feeds** | vault-health, bridge-ai-advisor | LINK/USD price oracle via `latestAnswer()` |
| **HTTPClient** | bridge-ai-advisor | AI policy analysis with `consensusIdenticalAggregation` |
| **CronCapability** | All 3 workflows | Autonomous scheduling (15-30 min intervals) |
| **getNetwork()** | All 3 workflows | Chain selector resolution for mainnet reads + Sepolia writes |
| **encodeCallMsg** | All 3 workflows | ABI-encoded contract call construction |

---

## Test Coverage

### Smart Contract Tests: 83 total (all passing)

| File | Tests | Type |
|------|-------|------|
| `LaneVault4626.t.sol` | 8 | Unit (core vault) |
| `LaneVault4626Fuzz.t.sol` | 4 | Fuzz (10K runs) |
| `LaneVault4626Invariant.t.sol` | 1 | Invariant (32 actions x 10K runs) |
| `LaneVault4626.EnhancedInvariants.t.sol` | 1 | 6-invariant fuzz (48 actions x 10K) |
| `LaneVault4626.Attacks.t.sol` | 14 | Attack scenarios |
| `SecurityAudit.Attacks.t.sol` | 10 | E2E security audit attacks (ATK-B01 to B10) |
| `LaneSettlementAdapter.t.sol` | 6 | Adapter unit + integration |
| `LaneVaultScaffold.t.sol` | 5 | Scaffold unit |
| `DeepAudit.t.sol` | 11 | Deep audit verification |
| `AdvancedAudit.t.sol` | 15 | Advanced edge cases (ADV-01 to ADV-15) |
| `E2E.t.sol` | 8 | Full lifecycle E2E (E2E-01 to E2E-08) |

**Fuzz statistics:** ~4.16M invariant assertions across 800K randomized action sequences at 10K fuzz iterations.

### E2E Test Coverage (E2E.t.sol)

| Test | Scenario |
|------|----------|
| E2E-01 | Happy path: deposit, reserve, fill, settle success, withdraw |
| E2E-02 | Queued redemption: full queue lifecycle with settlement |
| E2E-03 | Multi-route mixed settlement: 3 routes with success, loss, and emergency |
| E2E-04 | Emergency release: stuck fill recovered after 72h timelock |
| E2E-05 | Fee claim then queue process: governance claims fees mid-cycle |
| E2E-06 | Multi-LP FIFO: 3 LPs with fair queue ordering |
| E2E-07 | Deposit after loss: new LP enters at correct (reduced) share price |
| E2E-08 | Reservation expiry then reuse: expired liquidity recycled |

---

## File Structure

```
workflows/
  vault-health/my-workflow/
    main.ts                    # CRE workflow (15-min vault monitoring)
    workflow.yaml              # CRE deployment config
    config.example.json        # Thresholds + registry address
    contracts/abi/             # Vault + queue + price feed ABIs

  bridge-ai-advisor/my-workflow/
    main.ts                    # CRE workflow (30-min AI analysis)
    workflow.yaml              # CRE deployment config
    config.example.json        # AI endpoint + registry config

  queue-monitor/my-workflow/
    main.ts                    # CRE workflow (15-min queue tracking)
    workflow.yaml              # CRE deployment config
    config.example.json        # Queue thresholds + registry

platform/
  bridge_analyze_endpoint.py   # Flask AI server (GPT-5.2)

scripts/
  bridge-unified-cycle.sh      # Phase 1.5 + 2 orchestration (Phase 1 on CRE DON)
  record-bridge-proofs.mjs     # On-chain proof writes (viem + Sepolia)
  composite-bridge-intelligence.mjs  # Cross-workflow correlation
```
