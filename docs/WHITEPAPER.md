# SDL CCIP Bridge: Technical Whitepaper

**Version:** 2.0
**Date:** March 3, 2026
**Authors:** Orbital Engineering

---

## Abstract

The SDL CCIP Bridge is a non-upgradeable, audited smart contract system that provides liquidity infrastructure for cross-chain asset bridging. The system combines an ERC-4626 LP vault with Chainlink CCIP for canonical settlement, Chainlink CRE (Runtime Environment) for autonomous monitoring, and AI-powered policy optimization via GPT-5.2 with DON consensus validation. Three CRE workflows run autonomously on the Chainlink Decentralized Oracle Network (DON), reading vault state every 15-30 minutes, classifying risk, and anchoring keccak256 proof hashes on-chain. A composite intelligence layer cross-correlates workflow outputs to detect ecosystem-level risks invisible to any single monitor.

This paper details the complete system: smart contracts, settlement mechanics, liquidity accounting, autonomous monitoring, AI integration, on-chain proof verification, and security properties.

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [System Architecture](#2-system-architecture)
3. [Smart Contract Layer](#3-smart-contract-layer)
4. [Liquidity Accounting Model](#4-liquidity-accounting-model)
5. [Bridge Lifecycle](#5-bridge-lifecycle)
6. [CCIP Settlement](#6-ccip-settlement)
7. [LP Experience](#7-lp-experience)
8. [Fee Economics](#8-fee-economics)
9. [Access Control and Pause Mechanism](#9-access-control-and-pause-mechanism)
10. [Autonomous Monitoring: CRE and DON](#10-autonomous-monitoring-cre-and-don)
11. [CRE Workflows](#11-cre-workflows)
12. [AI-Powered Policy Optimization](#12-ai-powered-policy-optimization)
13. [Composite Intelligence](#13-composite-intelligence)
14. [On-Chain Proof System](#14-on-chain-proof-system)
15. [Trust Model and Verification](#15-trust-model-and-verification)
16. [Security](#16-security)
17. [Deployments](#17-deployments)
18. [Future Considerations](#18-future-considerations)

---

## 1. Introduction

### 1.1 Problem Statement

Cross-chain asset bridging faces three fundamental challenges:

1. **Liquidity fragmentation:** Bridge protocols require destination-chain liquidity that is typically locked in protocol-owned pools, creating capital inefficiency and centralization risk.

2. **Settlement latency:** Canonical cross-chain messaging (e.g., optimistic rollup finality) can take minutes to hours, creating poor user experience.

3. **Trust assumptions:** Most bridge designs require users to trust either a multisig, a relayer set, or an optimistic fraud-proof window. These introduce systemic risk that has historically resulted in billions of dollars in bridge exploits.

4. **No real-time monitoring:** Bridge vaults operate without visibility into utilization spikes, liquidity crunches, queue buildup, or bad debt accumulation until it's too late.

### 1.2 Solution

The SDL CCIP Bridge addresses these challenges through a multi-layered architecture:

**Settlement layer:** An ERC-4626 LP vault with Chainlink CCIP as the canonical settlement mechanism. Liquidity Providers deposit assets, bonded solvers provide instant destination-chain fulfillment, and CCIP messages reconcile the accounting.

**Monitoring layer:** Three Chainlink CRE workflows running autonomously on the DON every 15-30 minutes, reading vault state, classifying risk, and writing proof hashes on-chain.

**Intelligence layer:** AI-powered policy optimization (GPT-5.2) with DON consensus validation, plus composite cross-workflow analysis that catches ecosystem-level risks.

This separation of concerns creates a system where:
- LPs bear liquidity risk (managed by the vault's 5-bucket accounting model)
- Solvers bear execution risk (managed by bonding and slashing)
- Neither party bears messaging risk (delegated to Chainlink CCIP)
- An autonomous DON monitors all of it continuously

---

## 2. System Architecture

### 2.1 Full System Overview

```
                    +---------------------------------------------------------+
                    |              Smart Contract Layer (Sepolia)               |
                    |                                                          |
                    |  +------------------+    +---------------------------+   |
   LP deposits ---> |  | LaneVault4626    |    | LaneSettlementAdapter     |   |
   LP withdrawals <- |  | (ERC-4626 vault  |    | (CCIP receiver with       | <--- CCIP Router
                    |  |  5-bucket model)  |    |  3-layer security)        |   |
                    |  +--------+---------+    +---------------------------+   |
                    |           |                                              |
                    |  +--------v---------+                                    |
                    |  | LaneQueueManager  |                                   |
                    |  | (FIFO redemption) |                                   |
                    |  +------------------+                                    |
                    +---------------------------------------------------------+
                                |
                    +-----------v---------------------------------------------+
                    |        CRE Monitoring Layer (Ethereum Mainnet DON)        |
                    |                                                          |
                    |  +----------------+  +------------------+  +----------+  |
                    |  | Vault Health   |  | Bridge AI Advisor |  | Queue    |  |
                    |  | Monitor        |  | (GPT-5.2 +       |  | Monitor  |  |
                    |  | (15 min)       |  |  DON consensus)  |  | (15 min) |  |
                    |  +-------+--------+  +--------+---------+  +----+-----+  |
                    |          |                    |                  |        |
                    |          +---------- All read vault state ------+        |
                    |                      via EVMClient                       |
                    +---------------------------------------------------------+
                                |
                    +-----------v---------------------------------------------+
                    |           Intelligence Layer (Local Scripts)              |
                    |                                                          |
                    |  +---------------------------+  +-----------------------+ |
                    |  | Composite Intelligence    |  | Proof Recording       | |
                    |  | (cross-workflow analysis) |  | (SentinelRegistry)    | |
                    |  +---------------------------+  +-----------------------+ |
                    +---------------------------------------------------------+
```

### 2.2 Design Principles

1. **Non-upgradeability:** All contracts are deployed as immutable implementations. No proxy patterns. What you audit is what runs forever.

2. **Chainlink-native:** CCIP for settlement, CRE for monitoring, Data Feeds for pricing. Single trust assumption: the Chainlink DON.

3. **Virtual accounting:** The vault tracks liquidity through 5 accounting buckets rather than relying on token balance deltas. This eliminates donation attack vectors.

4. **Defense in depth:** Every layer has redundant safety checks. The settlement adapter has 3 validation layers. The vault has inline invariant assertions. The CRE workflows have independent risk classification.

5. **Verifiable AI:** Every AI recommendation is hashed and anchored on-chain. The DON validates AI consensus before acceptance.

---

## 3. Smart Contract Layer

### 3.1 Contract Summary

| Contract | LOC | Purpose |
|----------|-----|---------|
| `LaneVault4626` | 616 | Core ERC-4626 vault with 5-bucket accounting, dual state machines, FIFO queue, role-based access |
| `LaneQueueManager` | 91 | Immutable FIFO redemption queue with strict no-cancel policy |
| `LaneSettlementAdapter` | 104 | Chainlink CCIP receiver with source allowlist, 3-tuple replay protection, payload domain binding |
| `LaneVaultScaffold` | 227 | Off-chain simulation parity contract (not deployed) |

**Total production nSLOC:** 766

### 3.2 Technology Stack

| Component | Version |
|-----------|---------|
| Solidity | 0.8.24 (Shanghai+, emits `PUSH0`) |
| OpenZeppelin Contracts | 5.0.2 |
| Chainlink CCIP | 1.6.1 |
| Forge Standard Library | Latest |
| Foundry | Build, test, deploy |

### 3.3 Chain Compatibility

Compatible with all Shanghai+ EVM chains: Ethereum Mainnet, Arbitrum (Nitro), Optimism (Bedrock), Base (Bedrock), Sepolia.

---

## 4. Liquidity Accounting Model

### 4.1 Five-Bucket Architecture

The vault tracks all assets across five mutually exclusive accounting buckets, denominated in the underlying asset unit (e.g., LINK):

```
+-------------------------------------------------------------------+
|                        Vault Total Assets                         |
|                                                                   |
|  +------------------+  +------------------+  +------------------+ |
|  | Free Liquidity   |  | Reserved         |  | In-Flight        | |
|  | (available for   |  | Liquidity        |  | Liquidity        | |
|  |  LP withdrawals  |  | (locked for      |  | (locked during   | |
|  |  and new routes) |  |  pending routes) |  |  CCIP settlement)| |
|  +------------------+  +------------------+  +------------------+ |
|                                                                   |
|  +------------------+  +------------------+                       |
|  | Bad Debt Reserve |  | Protocol Fee     |                       |
|  | (self-funding    |  | Accrued          |                       |
|  |  loss buffer)    |  | (governance-     |                       |
|  |                  |  |  claimable)      |                       |
|  +------------------+  +------------------+                       |
+-------------------------------------------------------------------+
```

**Key properties:**

1. **No commingling:** Each asset unit exists in exactly one bucket at any time.
2. **Conservation:** Every state transition moves assets between buckets with exact arithmetic. No rounding in bucket transitions.
3. **LP NAV exclusion:** `totalAssets()` returns `free + reserved + inFlight - protocolFees`, ensuring protocol fees are excluded from LP share pricing immediately upon accrual.

### 4.2 Accounting Invariants

Two invariants are checked inline after every state-mutating function via `_assertAccountingInvariants()`:

```solidity
require(badDebtReserveAssets <= freeLiquidityAssets);
require(protocolFeeAccruedAssets <= freeLiquidityAssets);
```

These ensure that the bad debt reserve and protocol fee accruals never exceed the free liquidity bucket. A third invariant is verified in the test suite:

```
freeLiquidityAssets + reservedLiquidityAssets + inFlightLiquidityAssets
  >= protocolFeeAccruedAssets + badDebtReserveAssets
```

### 4.3 Phantom Asset Prevention

Settlement success credits fee income to the LP NAV. To prevent crediting phantom assets (fees claimed without actual token arrival), the `reconcileSettlementSuccess` function verifies the vault's actual token balance before any accounting updates:

```solidity
uint256 requiredBalance = currentHeld + netFeeIncomeAssets;
uint256 actualBalance = IERC20(asset()).balanceOf(address(this));
if (actualBalance < requiredBalance) revert BalanceDeficit(requiredBalance, actualBalance);
```

---

## 5. Bridge Lifecycle

### 5.1 Participants

The bridge operates with three participant types:

| Participant | Role | Risk |
|-------------|------|------|
| **Liquidity Provider (LP)** | Deposits assets into the vault, receives ERC-4626 share tokens, earns fees from bridge settlement activity | Liquidity risk (utilization, loss events) |
| **Solver** | Provides instant destination-chain fulfillment using own capital, reimbursed with fees after CCIP settlement | Execution risk (failed fills, slashing) |
| **Operator** | Manages bridge routes: reserves liquidity, coordinates fills, processes redemption queue | Operational risk (missed expiry, queue processing) |

### 5.2 Dual State Machines

The bridge lifecycle is modeled as two interleaved state machines:

**Route State Machine:**
```
          reserve()           release()
  None ---------> Reserved -----------> Released
                      |
                      | executeFill()
                      v
                    Filled ------------> SettledSuccess
                      |                     (via reconcileSettlementSuccess)
                      |
                      +----------------> SettledLoss
                                            (via reconcileSettlementLoss
                                             or emergencyReleaseFill)
```

**Fill State Machine:**
```
           executeFill()
  None ---------------> Executed -------> SettledSuccess
                          |
                          +--------------> SettledLoss
```

### 5.3 Lifecycle Flow

**Step 1: LP Deposits.** LPs deposit assets (e.g., LINK) into the ERC-4626 vault, receiving share tokens that represent proportional ownership. Deposited assets enter the `freeLiquidityAssets` bucket.

**Step 2: Reserve.** An operator identifies a bridge intent on the source chain and reserves `amount` assets from free liquidity for `routeId` with an `expiry` timestamp. The utilization cap (`maxUtilizationBps`) is enforced. Assets move from `free` to `reserved`.

**Step 3: Fill.** A solver provides instant destination-chain fulfillment to the bridge user. The operator records this fill by moving `amount` from `reserved` to `inFlight`. The fill is now awaiting CCIP settlement.

**Step 4: CCIP Settlement.** A canonical CCIP message arrives from the source chain containing the settlement payload. The adapter validates and routes it to the vault:
- **Success:** Principal returns to `free`, fee income is distributed across LP yield, bad debt reserve, and protocol fee.
- **Loss:** Recovered amount returns to `free`, shortfall is absorbed by the bad debt reserve. Uncovered loss hits LP NAV.

**Step 5: LP Withdrawal.** LPs withdraw from free liquidity. If free liquidity is insufficient, they join the FIFO redemption queue.

### 5.4 Reservation Expiry

Reservations include an `expiry` timestamp. After expiry, anyone can call `expireReservation(routeId)` to release the locked liquidity back to free. This is **permissionless**, requiring no role. This prevents operator negligence from indefinitely locking LP funds.

### 5.5 Emergency Release

If a fill is stuck in `Executed` state for longer than `emergencyReleaseDelay` (default 72 hours), governance can release it via `emergencyReleaseFill`. This treats the stuck fill as a loss, absorbing via the bad debt reserve.

---

## 6. CCIP Settlement

### 6.1 Architecture

The `LaneSettlementAdapter` extends Chainlink's `CCIPReceiver` base contract. It is the sole holder of `SETTLEMENT_ROLE` on the vault. No EOA can call settlement functions directly.

```
Source Chain                              Destination Chain
+-----------+                             +-----------+
| Bridge    | --- CCIP message ---------> | CCIP      |
| Contract  |    (settlement payload)     | Router    |
+-----------+                             +-----+-----+
                                                |
                                          +-----v-----+
                                          | Settlement |
                                          | Adapter    |
                                          | (validate) |
                                          +-----+-----+
                                                |
                                          +-----v-----+
                                          | LaneVault  |
                                          | (reconcile)|
                                          +-----------+
```

### 6.2 Three-Layer Security Model

**Layer 1: Source Allowlist.** Only registered `(chainSelector, sender)` pairs are accepted. Messages from unauthorized chains or contracts are rejected.

```solidity
if (!isAllowedSource[message.sourceChainSelector][sourceSender])
    revert SourceNotAllowed();
```

**Layer 2: 3-Tuple Replay Protection.** Each message is uniquely identified by `keccak256(sourceChainSelector, sourceSender, messageId)`. Consumed messages are tracked in a mapping. Duplicates are rejected.

```solidity
bytes32 replayKey = keccak256(abi.encode(sourceChainSelector, sourceSender, messageId));
if (replayConsumed[replayKey]) revert ReplayDetected(replayKey);
replayConsumed[replayKey] = true;
```

**Layer 3: Payload Domain Binding.** The payload itself contains redundant safety checks: protocol version, target vault address, and chain ID must all match the destination deployment.

```solidity
if (payload.version != PAYLOAD_VERSION) revert InvalidPayload("invalid_version");
if (payload.targetVault != address(vault)) revert InvalidPayload("invalid_vault");
if (payload.chainId != block.chainid) revert InvalidPayload("invalid_chainid");
```

### 6.3 Settlement Payload

```solidity
struct SettlementPayload {
    uint16 version;             // Protocol version (currently 1)
    address targetVault;        // Expected vault address on this chain
    uint256 chainId;            // Expected chain ID
    bytes32 routeId;            // Bridge route identifier
    bytes32 fillId;             // Fill identifier
    bool success;               // True = success path, false = loss path
    uint256 principalAssets;    // Original fill amount
    uint256 netFeeIncomeAssets; // Fee income (success path only)
    uint256 recoveredAssets;    // Recovered amount (loss path only)
}
```

### 6.4 Atomic Revert Behavior

If `_ccipReceive` reverts for any reason (validation failure, vault revert), **all state changes are atomically rolled back**, including the replay key consumption. The CCIP Router marks the message as `FAILURE`. The message can be manually re-executed via the Chainlink CCIP Explorer once the root cause is resolved. No partial state corruption is possible.

---

## 7. LP Experience

### 7.1 ERC-4626 Compliance

The vault implements the full ERC-4626 standard for tokenized vaults:

| Function | Behavior |
|----------|----------|
| `deposit(assets, receiver)` / `mint(shares, receiver)` | Deposit assets, receive share tokens |
| `withdraw(assets, receiver, owner)` / `redeem(shares, receiver, owner)` | Withdraw from free liquidity |
| `maxDeposit()` / `maxMint()` | Returns 0 when paused (spec compliance) |
| `maxWithdraw(owner)` / `maxRedeem(owner)` | Bounded by available free liquidity |
| `totalAssets()` | LP NAV excluding protocol fees |
| `convertToShares()` / `convertToAssets()` | Share-asset conversion with OZ rounding |

### 7.2 Inflation Attack Protection

The vault uses a virtual decimals offset of 3 (`_decimalsOffset() = 3`), creating a 1000:1 share-to-asset multiplier. This makes first-depositor inflation attacks economically unviable. An attacker would need to donate 1000x the expected profit to manipulate the exchange rate by 1 share.

OpenZeppelin 5.0.2 implements conservative rounding that always favors the vault:

| Function | Rounds | Effect |
|----------|--------|--------|
| `previewDeposit` | Down | LP gets fewer shares |
| `previewMint` | Up | LP pays more assets |
| `previewWithdraw` | Up | LP burns more shares |
| `previewRedeem` | Down | LP gets fewer assets |

### 7.3 FIFO Redemption Queue

When free liquidity is insufficient for a full withdrawal, LPs can use `requestRedeem(shares, receiver, owner)` to join a strict FIFO queue:

1. Shares are **escrowed** in the vault (transferred from owner to vault contract)
2. Request is **non-cancelable** once enqueued (prevents gaming)
3. `OPS_ROLE` calls `processRedeemQueue(maxRequests)` as free liquidity becomes available
4. Each request is processed at the **current exchange rate** at processing time (not request time)
5. Processing stops when free liquidity is insufficient for the next request

**Queue properties:** O(1) enqueue and dequeue, strict FIFO ordering (no priority lanes), request IDs reset when queue empties.

### 7.4 Transfer Allowlist

During launch phase, share token transfers are restricted to allowlisted addresses. This prevents secondary market trading before the vault's economic parameters are proven. Governance can permanently disable the allowlist once the vault is mature. Mint, burn, and vault-internal transfers (escrow) are always exempt.

---

## 8. Fee Economics

### 8.1 Fee Distribution

When a bridge fill settles successfully, the `netFeeIncome` is distributed:

```
netFeeIncome
  |
  +-- badDebtReserveCutBps (default 10%) --> badDebtReserveAssets
  |
  +-- protocolFeeBps (default 0%)        --> protocolFeeAccruedAssets
  |
  +-- remainder                          --> freeLiquidityAssets (LP NAV)
```

### 8.2 Bad Debt Reserve

The bad debt reserve is a self-funding loss buffer:

- **Funded by:** A percentage cut of every successful settlement's fee income
- **Used when:** A settlement resolves as a loss. The reserve absorbs the loss up to its current balance.
- **Shortfall:** Any loss exceeding the reserve directly reduces `freeLiquidityAssets`, diluting LP NAV.

This creates a natural insurance mechanism where high-volume, successful bridge activity builds up a reserve that protects LPs during rare loss events.

### 8.3 Protocol Fee Safety Rail

The protocol fee has a hard cap (`protocolFeeCapBps`, default 10%). If governance attempts to set `protocolFeeBps` above the cap, the value is silently set to 0 as a fail-safe. This prevents governance from extracting excessive fees.

### 8.4 Policy Parameters

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `badDebtReserveCutBps` | 1000 (10%) | 0-10000 | Fee income allocated to bad debt reserve |
| `maxUtilizationBps` | 6000 (60%) | 0-10000 | Maximum utilization cap (reserved + in-flight) |
| `targetHotReserveBps` | 2000 (20%) | 0-10000 | Advisory hint for off-chain keeper |
| `protocolFeeBps` | 0 (0%) | 0-protocolFeeCapBps | Protocol fee percentage |
| `protocolFeeCapBps` | 1000 (10%) | 0-10000 | Hard cap on protocol fee |
| `emergencyReleaseDelay` | 3 days | >= 1 day | Timelock for stuck fill emergency release |

---

## 9. Access Control and Pause Mechanism

### 9.1 Role Hierarchy

```
DEFAULT_ADMIN_ROLE (timelock: configurable, default 2 days)
  |
  +-- GOVERNANCE_ROLE
  |     - setPolicy(), setSettlementAdapter(), setTransferAllowlist*()
  |     - claimProtocolFees(), emergencyReleaseFill(), setEmergencyReleaseDelay()
  |
  +-- OPS_ROLE
  |     - reserveLiquidity(), releaseReservation(), executeFill()
  |     - processRedeemQueue()
  |
  +-- PAUSER_ROLE
  |     - setPauseFlags()
  |
  +-- SETTLEMENT_ROLE (adapter-only, never an EOA)
        - reconcileSettlementSuccess(), reconcileSettlementLoss()
```

Admin role transfer uses OpenZeppelin's `AccessControlDefaultAdminRules`: 2-step transfer with configurable timelock. Current admin begins transfer, timelock elapses, new admin accepts.

### 9.2 Granular Pause Flags

| Flag | Scope | Operations Blocked |
|------|-------|--------------------|
| `globalPaused` | Everything | All state-mutating operations |
| `depositPaused` | Deposits | deposit, mint |
| `reservePaused` | Bridge ops | reserveLiquidity, releaseReservation, executeFill |

`expireReservation()` is NOT affected by any pause flag, always available to prevent permanent liquidity lockup.

The deployment script deploys the vault **fully paused**. Operations must be explicitly unpaused after configuration is complete.

---

## 10. Autonomous Monitoring: CRE and DON

### 10.1 What is CRE?

Chainlink's Runtime Environment (CRE) allows developers to define workflows in TypeScript that execute autonomously on the Decentralized Oracle Network (DON). CRE workflows have access to built-in capabilities:

| Capability | Purpose |
|------------|---------|
| `EVMClient` | Read smart contract state (up to 15 calls per execution) |
| `HTTPClient` | Make external API calls with DON consensus |
| `CronCapability` | Schedule autonomous execution at fixed intervals |
| `getNetwork()` | Resolve chain selectors for cross-chain operations |
| `encodeCallMsg` | Construct ABI-encoded contract calls |

### 10.2 Why Autonomous Monitoring?

Traditional bridge monitoring requires centralized infrastructure: a server polling contracts, a database storing history, and alerting systems. These introduce single points of failure.

CRE changes this:
- **Decentralized execution:** Multiple independent DON nodes run the same workflow
- **No infrastructure:** No server to maintain, no database to manage
- **Built-in consensus:** All nodes must agree on results before acceptance
- **Autonomous scheduling:** `CronCapability` triggers execution without external cron jobs
- **Same code, different trust:** The same TypeScript workflow runs locally in `simulate` mode and on the DON in production

### 10.3 Three-Phase Architecture

The monitoring system operates in three phases:

```
Phase 1:    CRE DON (autonomous, on-chain cron)
              All 3 workflows registered on Ethereum mainnet Workflow Registry.
              DON nodes execute them autonomously every 15-30 minutes.
              No local infrastructure needed.

Phase 1.5:  Composite Intelligence (local script)
              Cross-correlates data across all 3 workflows.
              Runs locally because CRE workflows are isolated by design
              (no shared state between workflows at runtime).

Phase 2:    On-Chain Proof Recording (local script)
              Writes keccak256 proof hashes to SentinelRegistry on Sepolia.
              Runs locally because the registry uses onlyOwner access control
              and the DON does not hold the owner's private key.
```

### 10.4 CRE 15-Read Limit

Each CRE workflow execution gets a maximum of 15 EVMClient calls. The SDL CCIP Bridge workflows are optimized to use 11 reads each, leaving headroom:

| Read # | Function | Purpose |
|--------|----------|---------|
| 1-4 | freeLiquidityAssets, reservedLiquidityAssets, inFlightLiquidityAssets, badDebtReserveAssets | Four liquidity buckets |
| 5-6 | totalAssets, totalSupply | ERC-4626 totals |
| 7-8 | maxUtilizationBps, badDebtReserveCutBps | Policy parameters |
| 9 | globalPaused | Emergency state |
| 10 | pendingCount | Queue depth |
| 11 | latestAnswer (LINK/USD) | Price for TVL calculation |

---

## 11. CRE Workflows

### 11.1 Vault Health Monitor

**Purpose:** Real-time 5-bucket liquidity monitoring with risk classification.

**Schedule:** Every 15 minutes via `CronCapability`

**Risk Classification:**
```
utilizationBps = (reserved + inFlight) * 10000 / totalAssets
reserveRatio = badDebtReserve / totalAssets
sharePrice = totalAssets / totalSupply

CRITICAL: utilization >= 90% OR reserveRatio < 2% OR queueDepth >= 20
WARNING:  utilization >= 70% OR reserveRatio < 5% OR queueDepth >= 5
OK:       all metrics within bounds
```

**Proof hash:** `keccak256(abi.encode(timestamp, "vault-health", risk, utilBps, totalAssets, freeLiq, queueDepth, reserveRatio, sharePrice))`

**On-chain output:** `SentinelRegistry.recordHealth(hash, "vault:ok|warning|critical")`

### 11.2 Bridge AI Advisor

**Purpose:** AI-powered policy optimization using GPT-5.2 via DON consensus.

**Schedule:** Every 30 minutes via `CronCapability`

**Architecture:**
```
CRE Workflow (each DON node independently)
    |
    +-- EVMClient: read vault state (11 contract reads)
    |
    +-- HTTPClient + consensusIdenticalAggregation:
    |     POST /api/cre/analyze-bridge
    |       Input:  all vault state metrics
    |       Model:  GPT-5.2
    |       Output: structured JSON recommendation
    |
    +-- All DON nodes must agree on the AI response
```

**Why `consensusIdenticalAggregation` matters:** All DON nodes independently call the AI endpoint. The aggregation requires every node to receive the **same response** before accepting it. This prevents any single node from injecting false AI recommendations. The AI endpoint is engineered for deterministic output (structured JSON with hash-seeded consistency).

**AI Response Structure:**
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

The AI recommends specific policy parameter adjustments (utilization cap, reserve cut, hot reserve target) based on the current vault state. These are advisory; governance must manually apply them.

**Cost:** ~$0.003-0.005 per analysis call (GPT-5.2).

**Proof hash:** `keccak256(abi.encode(timestamp, "bridge-advisor", risk, utilBps, queueDepth, confidence))`

### 11.3 Queue Monitor

**Purpose:** FIFO redemption queue health tracking and liquidity coverage analysis.

**Schedule:** Every 15 minutes via `CronCapability`

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

**Proof hash:** `keccak256(abi.encode(timestamp, "queue-monitor", risk, queueDepth, coverageRatio, utilBps))`

---

## 12. AI-Powered Policy Optimization

### 12.1 AI Analysis Endpoint

The bridge-ai-advisor workflow calls a Flask server (`platform/bridge_analyze_endpoint.py`) that:

1. Receives vault state metrics as JSON
2. Constructs a structured prompt with all liquidity bucket values, policy parameters, queue state, and LINK/USD price
3. Calls GPT-5.2 via OpenAI Chat Completions API with `temperature=0` for deterministic output
4. Strips null values from the response (null values crash CRE consensus)
5. Returns structured JSON: risk level, recommendation, suggested actions, policy adjustments, confidence score, reasoning

### 12.2 Deterministic AI Output

CRE's `consensusIdenticalAggregation` requires all DON nodes to receive byte-identical responses. Achieving this with an AI model requires:

1. **Temperature 0:** Eliminates sampling randomness
2. **Structured JSON schema:** Forces the model to output in a fixed format
3. **Hash-seeded prompts:** The prompt includes a hash of the input metrics, seeding consistent analysis
4. **Null stripping:** Server-side removal of null/undefined values that would break consensus serialization
5. **Fixed field ordering:** JSON keys are always serialized in the same order

### 12.3 Heuristic Fallback

When the AI API is unavailable, the endpoint falls back to a rule-based heuristic that evaluates the same metrics using hard-coded thresholds. This ensures the workflow always produces a result, even during API outages.

### 12.4 What Makes This Novel

The bridge-ai-advisor is the first CRE workflow that uses AI to recommend on-chain governance parameter changes with DON consensus validation. Previous CRE workflows read data and report status. This workflow reads data, reasons about it with AI, and proposes actionable policy changes, all validated by decentralized consensus.

---

## 13. Composite Intelligence

### 13.1 Why Cross-Workflow Analysis?

CRE workflows are isolated by design. Each runs independently on the DON with no shared state. This isolation is a security feature, but it means no single workflow can see the full picture.

Example: high utilization alone might be fine (normal operations). A growing queue alone might be fine (temporary liquidity crunch). The AI flagging a warning alone might be noise. But all three signals together indicate an LP liquidity crisis that needs immediate attention.

### 13.2 Cross-Correlation Logic

After all 3 CRE workflows complete, a local composite intelligence script cross-correlates their outputs:

```
Signal Escalation Matrix:
Single workflow warning   -> no escalation
Two workflows warning     -> composite WARNING
Any workflow critical     -> composite WARNING
Two+ workflows critical   -> composite CRITICAL
High util + growing queue + AI flagging -> CRITICAL (cascade)
```

### 13.3 Cascade Detection

The most valuable signal is cascade detection: when metrics across workflows are individually "only" warning-level but collectively indicate systemic stress.

**Example cascade:**
- Vault Health: utilization at 75% (warning)
- Queue Monitor: 8 pending redemptions (warning)
- AI Advisor: "reduce utilization cap" with 0.85 confidence

No single metric is critical. But the combination signals: LPs are trying to exit, utilization is climbing, and the AI sees the trend. The composite layer escalates to CRITICAL before any individual monitor would.

### 13.4 Optional AI Composite Analysis

The composite intelligence layer can optionally call `POST /api/cre/analyze-bridge-composite` with all three workflow snapshots, getting a natural-language reasoning about cross-workflow patterns and ecosystem-level risk assessment.

---

## 14. On-Chain Proof System

### 14.1 SentinelRegistry Contract

Every workflow run produces an immutable on-chain proof: a `HealthRecorded` event on the SentinelRegistry contract containing the keccak256 hash of the workflow's metrics.

**Contract:** `0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40` (Sepolia)

**Interface:**
```solidity
function recordHealth(bytes32 snapshotHash, string calldata riskLevel) external onlyOwner
function latest() external view returns (bytes32 hash, string memory level, uint256 ts)
function count() external view returns (uint256)
function recorded(uint256 index) external view returns (bytes32 hash, string memory level, uint256 ts)
```

**Properties:**
- Ownable2Step (2-step ownership transfer)
- Immutable records: once written, a proof cannot be altered
- O(1) access for latest, count, and index queries
- Deduplication: `AlreadyRecorded` revert on duplicate hashes
- Risk level capped at 256 bytes

### 14.2 Hash Encoding Consistency

Proof hashes use `keccak256(abi.encode(...))` with consistent field ordering between:
- CRE workflow TypeScript (using viem's `encodeAbiParameters`)
- Proof recording script (`scripts/record-bridge-proofs.mjs`)
- Solidity verification (matching `abi.encode` layout)

This ensures any party can independently reproduce the hash from the same block state.

### 14.3 Prefixed Risk Levels

Each workflow tags its risk level with a source prefix, making on-chain records self-describing:

```
vault:ok       vault:warning       vault:critical
advisor:ok     advisor:warning     advisor:critical
queue:ok       queue:warning       queue:critical
bridge-composite:ok  bridge-composite:warning  bridge-composite:critical
```

A `HealthRecorded` event with `riskLevel = "advisor:critical"` is immediately traceable to the bridge-ai-advisor workflow.

---

## 15. Trust Model and Verification

### 15.1 Current Trust Model (Hackathon)

```
CRE Workflow (local simulate + DON execution)
       |
  Snapshot JSON (real vault data via EVMClient)
       |
  keccak256 hash
       |
  Single deployer key -> SentinelRegistry (Sepolia)
```

The CRE workflows are deployed and active on the Ethereum mainnet DON, executing autonomously. The EVMClient reads are real (mainnet contract state via the DON's RPC infrastructure). The DON provides decentralized execution and consensus.

The proof recording step still uses a single owner key because SentinelRegistry uses `onlyOwner` access control. The data is *verifiable* (anyone can recompute the hash from the same block state) but proof writing is centralized.

### 15.2 Production Trust Model (DON Attestation)

```
CRE Workflow (Decentralized Oracle Network)
       |
  N independent oracle nodes execute the same workflow
       |
  Consensus on results (f+1 agreement)
       |
  Attested proof -> On-chain (trustless)
```

With DON-native proof attestation, no single party can fabricate results. The observation, computation, and attestation are all decentralized. Chainlink's DON provides Byzantine fault tolerance.

### 15.3 How to Verify a Proof

**Step 1:** Get the snapshot data (JSON with metrics and timestamp).

**Step 2:** Reproduce the hash using viem:

```javascript
import { keccak256, encodeAbiParameters, parseAbiParameters } from 'viem';

const encoded = encodeAbiParameters(
  parseAbiParameters(
    'uint256 ts, string wf, string risk, uint256 utilBps, uint256 totalAssets, ...'
  ),
  [timestamp, 'vault-health', 'ok', utilBps, totalAssets, ...],
);
const hash = keccak256(encoded);
```

**Step 3:** Query `HealthRecorded` events on the SentinelRegistry contract and match the hash. If your computed hash matches an on-chain `snapshotHash`, the data is verified.

### 15.4 What CRE Adds Over Simple Hashing

The value isn't just the hashing. CRE provides:

1. **Standardized workflow format:** Portable, auditable TypeScript + YAML definitions
2. **Built-in capabilities:** EVMClient for reads, HTTPClient for API calls, CronCapability for scheduling
3. **Path to decentralization:** Same code runs locally in `simulate` mode and on the DON in production
4. **AI consensus:** `consensusIdenticalAggregation` ensures all nodes agree before acceptance
5. **Chain-agnostic networking:** Read from Ethereum mainnet, write to Sepolia, in a single execution

---

## 16. Security

### 16.1 Smart Contract Security

| Feature | Implementation |
|---------|---------------|
| Reentrancy guard | `nonReentrant` on all state-mutating functions |
| Inline invariants | `_assertAccountingInvariants()` after every state change |
| Virtual accounting | Ignores balance changes, tracks bucket amounts |
| Inflation protection | `_decimalsOffset() = 3` (1000:1 virtual multiplier) |
| Phantom asset prevention | Balance check before crediting fee income |
| Transfer allowlist | Launch-phase restriction (permanently disableable) |
| Non-upgradeable | Immutable deployment, no proxy pattern |
| Admin transfer | 2-step via `AccessControlDefaultAdminRules` with timelock |
| Emergency release | 72h default timelock for stuck fills |
| Permissionless expiry | Anyone can release expired reservations |

### 16.2 Settlement Adapter Security

| Layer | Protection |
|-------|-----------|
| Source allowlist | Only registered `(chainSelector, sender)` pairs accepted |
| 3-tuple replay | `keccak256(sourceChainSelector, sender, messageId)` prevents duplicate processing |
| Domain binding | `version`, `targetVault`, `chainId` must match deployment |
| Atomic revert | On `_ccipReceive` revert, CCIP marks message as FAILURE for manual retry |

### 16.3 CRE/AI Security

| Feature | Implementation |
|---------|---------------|
| DON consensus | `consensusIdenticalAggregation` on all AI responses |
| Null safety | Server-side null stripping (null values crash CRE consensus) |
| Auth | `X-CRE-Secret` header authentication on AI endpoint |
| Heuristic fallback | Rule-based analysis when AI API is unavailable |
| Hash consistency | Matching `encodeAbiParameters` field ordering across TypeScript and Solidity |
| Proof immutability | SentinelRegistry records cannot be altered after writing |
| Deduplication | `AlreadyRecorded` revert prevents duplicate hash entries |

### 16.4 Security Audits

Three independent audits completed:

| Audit | Date | Methodology | Findings |
|-------|------|-------------|----------|
| Phase 1 (9-phase) | 2026-03-01 | Threat modeling, line-by-line, static analysis, fuzz, invariant | 0C, 0H, 2M, 3L, 3I |
| Deep re-audit | 2026-03-01 | CCIP-specific, EVM edge cases, gas griefing, formal verification | 11 checks, 4 actionable (all fixed) |
| CRE/AI audit | 2026-03-03 | Hash encoding, workflow format, auth, error handling | 2C, 2H, 4M, 2L (all fixed) |

### 16.5 Test Suite

**83 tests across 11 test files**, all passing.

| Category | Tests | Description |
|----------|-------|-------------|
| Core vault | 8 | Deposits, queue, routes, roles, pauses |
| Fuzz | 4 | Share conservation, FIFO fairness, settlement isolation (10K runs) |
| Invariant | 2 | 32-action and 48-action state machines with 6 invariants |
| Attack scenarios | 24 | Donation, reentrancy, replay, inflation, fake fills |
| Adapter | 6 | Source allowlist, replay, payload validation |
| Deep audit | 11 | Balance coverage, phantom assets, ERC-4626 compliance |
| Advanced edge cases | 15 | ADV-01 through ADV-15 |
| E2E lifecycle | 8 | Full bridge lifecycle (E2E-01 through E2E-08) |
| Scaffold | 5 | Off-chain simulation parity |

**Invariant coverage:** ~4.16M assertions across 800K randomized action sequences at 10K fuzz iterations.

### 16.6 Gas Analysis

| Operation | Estimated Gas |
|-----------|--------------|
| `deposit` | ~85K |
| `withdraw` | ~80K |
| `requestRedeem` | ~95K |
| `processRedeemQueue` (per item) | ~85K |
| `reserveLiquidity` | ~70K |
| `executeFill` | ~65K |
| `reconcileSettlementSuccess` | ~90K |
| `reconcileSettlementLoss` | ~75K |

Queue griefing economics: an attacker creating 1-share redemption requests spends ~80K gas per request to create, while the protocol spends ~85K to process. The attacker burns more gas than the protocol, making griefing economically unviable.

---

## 17. Deployments

### 17.1 Smart Contracts (Sepolia Demo)

| Contract | Address |
|----------|---------|
| MockERC20 (mLINK) | `0xf59f724C38BdDe189DEe900aD05305ca007161ed` |
| LaneVault4626 | `0x5962FBf9EA3398400869c91f1B39860264d6dB24` |
| LaneSettlementAdapter | `0x88D335531431FecEBFF8619AFF0c2F28Fd3477C1` |
| LaneQueueManager | `0xC40Ad4387B75D5BA8BF90b2ce35Ba0062b53aC9B` |
| SentinelRegistry | `0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40` |

State: vault has 50,200 mLINK TVL, one completed bridge lifecycle simulation (reserve + fill + settle), 20 mLINK bad debt reserve, 4 proof hashes on-chain.

### 17.2 CRE Workflows (Ethereum Mainnet)

All 3 workflows registered on the Chainlink Workflow Registry (`0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`):

| Workflow | Workflow ID | Registration Tx |
|----------|-------------|-----------------|
| vault-health | `004fe882fa92634fcb35f608fa94e76f635fb2f8e867d76328fe69e7f64d71d3` | [0x622162af...](https://etherscan.io/tx/0x622162af5e1380dbeb71ec7ae2482e1f3d8e518c1c899bc7b102dc83d3012269) |
| bridge-ai-advisor | `00460bc80aef935e416083628b1f00f82c1014f5dcc4e42f847832da2951911f` | [0xd9a942ff...](https://etherscan.io/tx/0xd9a942ffc080d140481e2920921b8e623573cdb528e47d7ce60ebe92cea9512e) |
| queue-monitor | `00f900d3da87de6cb1b4bf3a7be2dd550e090f8bbb6a96841275307d20b61e72` | [0x3e1629cd...](https://etherscan.io/tx/0x3e1629cd7401a6086784423118983fe9b31ce5e1f17b4f526a147f89fde94fb5) |

### 17.3 AI Analysis Endpoint

| Field | Value |
|-------|-------|
| URL | `sentinel-ai.schuna.co.il/api/cre/analyze-bridge` |
| Model | GPT-5.2 |
| Auth | `X-CRE-Secret` header |
| Cost | ~$0.003-0.005 per call |

### 17.4 Chainlink Products Used

| Product | Usage |
|---------|-------|
| CCIP | Core settlement layer (CCIPReceiver, source allowlist, replay protection, domain binding) |
| CRE SDK | All 3 workflow definitions (Runner, handler, CronCapability, EVMClient, HTTPClient) |
| EVMClient | 11 mainnet contract reads per workflow (vault buckets, policy, queue, pause state) |
| Workflow Registry | All 3 workflows registered on Ethereum mainnet via UpsertWorkflow |
| Data Feeds | LINK/USD price oracle (AggregatorV3 latestAnswer) |
| HTTPClient | AI policy analysis with consensusIdenticalAggregation |
| CronCapability | Autonomous scheduling (15-30 min intervals) |
| getNetwork() | Chain selector for mainnet reads + Sepolia writes |

---

## 18. Future Considerations

### 18.1 Multi-Lane Support

The current design supports one lane (source-destination pair) per vault deployment. Multi-lane support would require either multiple vault deployments (simpler, isolated risk) or a multi-lane extension with per-lane accounting (more capital efficient, higher complexity).

### 18.2 Automated Queue Processing

Redemption queue processing is currently manual (`OPS_ROLE`). Integration with Chainlink Automation would enable automatic processing when free liquidity becomes available.

### 18.3 Dynamic Fee Pricing

Future iterations could implement dynamic fee pricing based on utilization, volatility, or cross-chain gas costs.

### 18.4 DON-Native Proof Writing

Currently, proof recording to SentinelRegistry requires a local script with the owner's private key. Future versions could use DON-attested proofs written directly by the CRE workflow, eliminating the local script dependency.

### 18.5 Multi-Chain CRE Monitoring

The same CRE workflow definitions could be deployed to monitor vault instances on multiple chains simultaneously, with composite intelligence correlating cross-chain vault states.

---

## Appendix A: Settlement Payload Encoding

```solidity
bytes memory data = abi.encode(
    SettlementPayload({
        version: 1,
        targetVault: 0x...,
        chainId: 1,
        routeId: bytes32(...),
        fillId: bytes32(...),
        success: true,
        principalAssets: 1000e18,
        netFeeIncomeAssets: 10e18,
        recoveredAssets: 0
    })
);
```

## Appendix B: ERC-4626 Rounding Behavior

OpenZeppelin 5.0.2 implements conservative rounding that always favors the vault:

| Function | Rounds | Direction | Effect |
|----------|--------|-----------|--------|
| `convertToShares(assets)` | Down | Fewer shares per asset | Favors vault |
| `convertToAssets(shares)` | Down | Fewer assets per share | Favors vault |
| `previewDeposit(assets)` | Down | LP gets fewer shares | Favors vault |
| `previewMint(shares)` | Up | LP pays more assets | Favors vault |
| `previewWithdraw(assets)` | Up | LP burns more shares | Favors vault |
| `previewRedeem(shares)` | Down | LP gets fewer assets | Favors vault |

Combined with the 1000:1 virtual offset, this rounding behavior makes share price manipulation economically meaningless.

## Appendix C: File Structure

```
src/
  LaneVault4626.sol          -- Core vault (616 LOC)
  LaneQueueManager.sol       -- FIFO queue (91 LOC)
  LaneSettlementAdapter.sol  -- CCIP receiver (104 LOC)
  LaneVaultScaffold.sol      -- Simulation scaffold (227 LOC)

workflows/
  vault-health/              -- 5-bucket monitoring + risk classification
  bridge-ai-advisor/         -- AI policy optimizer (HTTPClient + consensus)
  queue-monitor/             -- FIFO queue + liquidity coverage tracking

scripts/
  bridge-unified-cycle.sh    -- Phase 1.5 + 2 orchestration
  record-bridge-proofs.mjs   -- On-chain proof writes to Sepolia
  composite-bridge-intelligence.mjs -- Cross-workflow correlation

platform/
  bridge_analyze_endpoint.py -- Flask AI analysis server (GPT-5.2)

test/
  11 test files, 83 tests total
```

---

*This whitepaper describes the SDL CCIP Bridge as deployed. The smart contracts are non-upgradeable: the behavior described here is permanent and immutable once deployed. The CRE workflows are live on the Ethereum mainnet DON, executing autonomously.*
