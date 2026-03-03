# Chainlink Usage in SDL CCIP Bridge

This document maps every Chainlink touchpoint in the codebase, as required for hackathon submission.

---

## 1. Chainlink CCIP: Settlement Layer (Smart Contracts)

The core bridge settlement uses Chainlink CCIP as its canonical cross-chain messaging protocol.

### `src/LaneSettlementAdapter.sol`

Extends `CCIPReceiver` from Chainlink CCIP SDK to receive cross-chain settlement messages:

```solidity
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
```

CCIP capabilities used:
- `CCIPReceiver._ccipReceive()`: processes settlement payloads (success or loss reconciliation)
- `Client.Any2EVMMessage`: typed message envelope from CCIP Router
- `IRouterClient.getFee()`: fee estimation for outbound messages
- Source chain allowlisting via `(chainSelector, sender)` tuples
- 3-tuple replay protection: `keccak256(sourceChainSelector, sender, messageId)`
- Payload domain binding: validates `version`, `targetVault`, `block.chainid`

### Settlement message flow

```
Source Chain (bridge origin)
  -> CCIP Router
    -> LaneSettlementAdapter._ccipReceive()
      -> SettlementPayload decoded (version, targetVault, chainId, fillId, success, amounts)
      -> vault.reconcileSettlementSuccess() or vault.reconcileSettlementLoss()
```

---

## 2. `@chainlink/cre-sdk`: Workflow Runtime

All 3 CRE workflows use the Chainlink CRE SDK as their execution runtime:

```typescript
import { cre, Runner, consensusIdenticalAggregation, getNetwork, encodeCallMsg } from '@chainlink/cre-sdk';
```

| File | SDK Usage |
|------|-----------|
| `workflows/vault-health/my-workflow/main.ts` | `Runner`, `cre.capabilities.EVMClient`, `cre.capabilities.CronCapability`, `getNetwork`, `encodeCallMsg` |
| `workflows/bridge-ai-advisor/my-workflow/main.ts` | `Runner`, `cre.capabilities.EVMClient`, `cre.capabilities.HTTPClient`, `cre.capabilities.CronCapability`, `consensusIdenticalAggregation`, `getNetwork`, `encodeCallMsg` |
| `workflows/queue-monitor/my-workflow/main.ts` | `Runner`, `cre.capabilities.EVMClient`, `cre.capabilities.CronCapability`, `getNetwork`, `encodeCallMsg` |

---

## 3. Chainlink EVM Client: On-Chain Reads

### `workflows/vault-health/my-workflow/main.ts`

Reads 11 state variables from LaneVault4626 and LaneQueueManager (CRE 15-read limit per workflow):

```typescript
// 4 core liquidity buckets (reads 1-4)
evmClient.callContract(runtime, { call: encodeCallMsg({ to: vault, data: freeLiquidityAssets }) })
evmClient.callContract(runtime, { call: encodeCallMsg({ to: vault, data: reservedLiquidityAssets }) })
evmClient.callContract(runtime, { call: encodeCallMsg({ to: vault, data: inFlightLiquidityAssets }) })
evmClient.callContract(runtime, { call: encodeCallMsg({ to: vault, data: badDebtReserveAssets }) })

// ERC-4626 totals (reads 5-6)
evmClient.callContract(runtime, { call: encodeCallMsg({ to: vault, data: totalAssets }) })
evmClient.callContract(runtime, { call: encodeCallMsg({ to: vault, data: totalSupply }) })

// Policy parameters (reads 7-8)
evmClient.callContract(runtime, { call: encodeCallMsg({ to: vault, data: maxUtilizationBps }) })
evmClient.callContract(runtime, { call: encodeCallMsg({ to: vault, data: badDebtReserveCutBps }) })

// Pause state (read 9)
evmClient.callContract(runtime, { call: encodeCallMsg({ to: vault, data: globalPaused }) })

// Queue depth (read 10)
evmClient.callContract(runtime, { call: encodeCallMsg({ to: queueManager, data: pendingCount }) })

// LINK/USD price feed (read 11)
evmClient.callContract(runtime, { call: encodeCallMsg({ to: linkUsdFeed, data: latestAnswer }) })
```

### `workflows/bridge-ai-advisor/my-workflow/main.ts`

Same vault reads as vault-health, plus feeds data to AI analysis via HTTPClient.

### `workflows/queue-monitor/my-workflow/main.ts`

Reads queue state in detail:

```typescript
// Queue management
evmClient.callContract(runtime, { call: encodeCallMsg({ to: queueManager, data: pendingCount }) })
evmClient.callContract(runtime, { call: encodeCallMsg({ to: queueManager, data: peek }) })
evmClient.callContract(runtime, { call: encodeCallMsg({ to: queueManager, data: headRequestId }) })
evmClient.callContract(runtime, { call: encodeCallMsg({ to: queueManager, data: tailRequestId }) })
```

---

## 4. Chainlink Data Feed: LINK/USD Price

### `workflows/vault-health/my-workflow/main.ts`

Reads Chainlink LINK/USD price feed to compute vault TVL in USD:

```typescript
// latestAnswer() from AggregatorV3Interface
evmClient.callContract(runtime, { call: encodeCallMsg({ to: linkUsdFeed, data: latestAnswer }) })
```

Feed address: `0xc59E3633BAAC79493d908e63626716e204A45EdF` (Sepolia testnet)

ABI file: `workflows/vault-health/contracts/abi/PriceFeedAggregator.ts`

---

## 5. Chainlink CRE HTTP Client: AI Analysis

### `workflows/bridge-ai-advisor/my-workflow/main.ts`

Uses `HTTPClient` with `consensusIdenticalAggregation` to call an AI analysis endpoint:

```typescript
const http = new cre.capabilities.HTTPClient();
const result = http
  .sendRequest(runtime, fetchAIAnalysis, consensusIdenticalAggregation<AIRecommendation>())
  ({ url, bearerToken, creSecret, vaultState })
  .result();
```

The AI endpoint (`platform/bridge_analyze_endpoint.py`) uses GPT-5.2 to analyze vault state and recommend policy adjustments. All DON nodes must receive identical AI response before accepting it.

Analysis produces:
- Risk classification (`ok|warning|critical`)
- Suggested policy adjustments (`maxUtilizationBps`, `badDebtReserveCutBps`, `targetHotReserveBps`)
- Confidence score and reasoning
- Actionable recommendations

---

## 6. Chainlink CRE Cron Trigger: Autonomous Scheduling

All 3 workflows use `CronCapability` for autonomous execution:

```typescript
const cron = new cre.capabilities.CronCapability();
return [cre.handler(cron.trigger({ schedule: config.schedule }), onCron)];
```

Schedules (configurable per workflow):
- `vault-health`: every 15 minutes (`0 */15 * * * *`)
- `bridge-ai-advisor`: every 30 minutes (`0 */30 * * * *`)
- `queue-monitor`: every 15 minutes (`0 */15 * * * *`)

Unified cycle runs 7x/day via `scripts/bridge-unified-cycle.sh`.

---

## 7. `getNetwork()`: Chain Selector Resolution

Used to resolve Chainlink chain selectors for both mainnet reads and Sepolia writes:

```typescript
// Mainnet vault reads
const net = getNetwork({ chainFamily: 'evm', chainSelectorName: 'ethereum-mainnet', isTestnet: false });
// Sepolia proof writes
const sepoliaNet = getNetwork({ chainFamily: 'evm', chainSelectorName: 'ethereum-testnet-sepolia', isTestnet: true });
```

---

## 8. SentinelRegistry: On-Chain Proof Writes (Sepolia)

All 3 CRE workflows write verifiable proof hashes to a SentinelRegistry contract on Sepolia. Proofs are computed as `keccak256(abi.encode(...workflow-specific metrics))`.

Contract: `0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40` (Sepolia, shared with Orbital Sentinel)

```solidity
function recordHealth(bytes32 snapshotHash, string calldata riskLevel) external onlyOwner
```

Risk levels:
- `vault:ok`, `vault:warning`, `vault:critical`
- `advisor:ok`, `advisor:warning`, `advisor:critical`
- `queue:ok`, `queue:warning`, `queue:critical`
- `bridge-composite:ok`, `bridge-composite:warning`, `bridge-composite:critical`

Hash encoding per workflow:

| Workflow | Encoded Fields |
|----------|---------------|
| vault-health | `(ts, 'vault-health', risk, utilBps, totalAssets, freeLiq, queueDepth, reserveRatio, sharePrice)` |
| bridge-advisor | `(ts, 'bridge-advisor', risk, utilBps, queueDepth, confidence)` |
| queue-monitor | `(ts, 'queue-monitor', risk, queueDepth, coverageRatio, utilBps)` |
| bridge-composite | `(ts, 'bridge-composite', risk, utilBps, queueDepth, confidence)` |

---

## 9. Composite Intelligence (Cross-Workflow)

After all 3 CRE workflows complete, a composite intelligence script (`scripts/composite-bridge-intelligence.mjs`) cross-correlates data from all workflows to produce ecosystem-aware risk assessments. This captures cross-workflow patterns that no single workflow can see in isolation.

Example: high utilization alone = ok, but high utilization + growing queue + AI advisor flagging = escalation.

The composite analysis optionally calls the AI endpoint for enhanced correlation, then writes a unified proof hash to SentinelRegistry.

---

## 10. Live CRE Workflow Registry (Ethereum Mainnet)

All 3 workflows are registered on the Chainlink Workflow Registry contract at `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`:

| Workflow | Workflow ID | Registration Tx |
|----------|-------------|-----------------|
| vault-health-staging | `004fe882fa92634fcb35f608fa94e76f635fb2f8e867d76328fe69e7f64d71d3` | `0x622162af...` |
| bridge-ai-advisor-staging | `00460bc80aef935e416083628b1f00f82c1014f5dcc4e42f847832da2951911f` | `0xd9a942ff...` |
| queue-monitor-staging | `00f900d3da87de6cb1b4bf3a7be2dd550e090f8bbb6a96841275307d20b61e72` | `0x3e1629cd...` |

Each workflow was compiled to WASM, uploaded to `storage.cre.chain.link`, and registered via `UpsertWorkflow`. Owner: `0xB250152756E2d6E3bD237a6875aE5E26e3D3877b`.

---

## Summary

| Chainlink Product | Where Used |
|-------------------|-----------|
| CCIP (CCIPReceiver, Client, IRouterClient) | `src/LaneSettlementAdapter.sol` (core settlement) |
| `@chainlink/cre-sdk` Runner + handler | All 3 workflow `main.ts` files |
| `EVMClient.callContract()` | All 3 workflows (vault + queue + price reads) |
| Chainlink Data Feeds (LINK/USD) | `workflows/vault-health/main.ts`, `workflows/bridge-ai-advisor/main.ts` |
| `HTTPClient` + `consensusIdenticalAggregation` | `workflows/bridge-ai-advisor/main.ts` (AI policy analysis) |
| `CronCapability` | All 3 workflows |
| `getNetwork()` chain selector | All 3 workflows |
| `SentinelRegistry.sol` (on-chain write) | All 3 workflows + composite intelligence + `scripts/record-bridge-proofs.mjs` |
| `encodeCallMsg` | All 3 workflows |
| Composite Intelligence (cross-workflow) | `scripts/composite-bridge-intelligence.mjs` |
| Workflow Registry (UpsertWorkflow) | All 3 workflows registered on Ethereum mainnet |
