# How SDL CCIP Bridge Works

> A plain-language guide to the vault mechanics, CRE monitoring, AI analysis, and on-chain proofs.

## The One-Liner

SDL CCIP Bridge is an ERC-4626 LP vault that earns fees from cross-chain bridge settlements via Chainlink CCIP, monitored autonomously by three CRE workflows that use AI to recommend policy changes and write verifiable proof hashes on-chain.

---

## What Problem Does This Solve?

Cross-chain bridges need liquidity. LPs provide that liquidity by depositing into a vault. But bridge vaults are complex: money flows in, gets locked for bridge operations, and comes back (hopefully with fees). If things go wrong, the LP can't withdraw, queues build up, and bad debt accumulates.

Most bridge vaults have no real-time monitoring. An operator might check a dashboard once a day. By then, a utilization spike or a liquidity crunch has already caused damage.

SDL CCIP Bridge solves both problems:
1. **The vault itself** tracks every wei across five accounting buckets, enforces utilization caps, and has a fair FIFO redemption queue
2. **The monitoring layer** watches the vault autonomously, uses AI to suggest parameter adjustments, and writes cryptographic proofs on-chain so anyone can verify the assessments

---

## The Vault: Five Buckets

Every asset in the vault lives in exactly one of five buckets:

| Bucket | What It Means | Example |
|--------|---------------|---------|
| **Free Liquidity** | Available for LP withdrawals and new bridge reservations | 800,000 LINK |
| **Reserved** | Locked for a pending bridge route (solver is about to fill) | 150,000 LINK |
| **In-Flight** | Locked during active CCIP settlement (message in transit) | 50,000 LINK |
| **Bad Debt Reserve** | Buffer to absorb losses from failed settlements | 10,000 LINK |
| **Protocol Fees** | Governance-claimable fees from settlement income | 5,000 LINK |

**The key invariant:** `totalAssets = free + reserved + inFlight - protocolFees`. This is checked after every single state change. If the math doesn't add up, the transaction reverts. No exceptions.

### Why Five Buckets?

In a simple vault, you just have "total balance." But bridge operations lock liquidity through multiple stages:

1. **LP deposits 1,000 LINK** -> goes to Free bucket
2. **Operator reserves 500 LINK for a bridge route** -> moves from Free to Reserved
3. **Solver fills the bridge on the destination chain** -> moves from Reserved to In-Flight
4. **CCIP settlement arrives** -> In-Flight returns to Free (plus fee income)

If the settlement reports a loss instead, the Bad Debt Reserve absorbs the shortfall so other LPs aren't directly impacted.

---

## The Bridge Lifecycle

Here's what happens when someone bridges an asset:

```
Step 1: LP deposits 1,000 LINK into the vault
        Receives share tokens (ERC-4626 standard)
        LINK goes to the Free Liquidity bucket

Step 2: Operator reserves 500 LINK for a bridge route
        500 LINK moves: Free -> Reserved
        Reservation has an expiry (if solver doesn't act, anyone can release it)

Step 3: Solver executes the fill on the destination chain
        500 LINK moves: Reserved -> In-Flight
        The solver provided instant liquidity to the bridger on the other chain

Step 4a: CCIP settlement SUCCESS
         500 LINK returns: In-Flight -> Free
         Fee income (e.g., 5 LINK) added to Free
         A cut goes to Bad Debt Reserve and Protocol Fees

Step 4b: CCIP settlement LOSS
         Bad Debt Reserve absorbs the shortfall
         If reserve isn't enough, LPs share the loss proportionally

Step 5: LP withdraws
        If enough Free Liquidity: instant withdrawal
        If not: LP joins the FIFO redemption queue
        Queue processes in order as liquidity becomes available
```

---

## The FIFO Queue

When an LP wants to withdraw but there isn't enough free liquidity, they join a queue. Important properties:

- **First-in, first-out:** requests are processed in the order they were submitted
- **Non-cancelable:** once you join the queue, your shares are locked (prevents gaming)
- **Shares are escrowed:** the vault holds your shares until the queue processes
- **Permissionless processing:** the operator calls `processRedeemQueue()` as free liquidity becomes available

**Why non-cancelable?** If LPs could cancel queue requests, they could grief the system: join the queue to lock up processing resources, then cancel right before processing. The FIFO + no-cancel design makes the queue deterministic and fair.

---

## CRE Monitoring: Three Workflows

### What is CRE?

CRE stands for **Compute Runtime Environment**. It's Chainlink's framework for running custom programs across their decentralized oracle network. Think of it as a server that nobody controls: your code runs on multiple oracle nodes, and they all have to agree on the result.

### Workflow 1: Vault Health Monitor (every 15 minutes)

**What it reads:**
| Data Point | Source | Why It Matters |
|-----------|--------|---------------|
| All 5 liquidity buckets | LaneVault4626 | Where is the money? |
| Utilization (reserved + inFlight) / total | LaneVault4626 | How much is locked up? |
| Share price (totalAssets / totalSupply) | LaneVault4626 | Are LPs gaining or losing value? |
| Queue depth | LaneQueueManager | How many LPs are waiting to exit? |
| Pause state | LaneVault4626 | Is the vault in emergency mode? |
| LINK/USD price | Chainlink Data Feed | For TVL calculation |

**How it classifies risk:**
- **OK:** utilization below 70%, reserve ratio above 5%, queue under 5
- **Warning:** utilization 70-90%, or reserve dipping below 5%, or queue growing
- **Critical:** utilization above 90%, or reserve below 2%, or queue above 20

### Workflow 2: Bridge AI Advisor (every 30 minutes)

This is the novel part. The workflow reads the same vault state, then sends it to a Claude Haiku AI model via CRE's `HTTPClient`.

**The AI receives:**
- Current utilization, queue depth, reserve ratio, share price
- Current policy parameters (utilization cap, reserve cut, hot reserve target)
- Free liquidity, total assets, LINK/USD price

**The AI recommends:**
```json
{
  "risk": "warning",
  "recommendation": "Reduce utilization cap to preserve LP exit capacity",
  "policyAdjustments": {
    "maxUtilizationBps": 5500,
    "badDebtReserveCutBps": null,
    "targetHotReserveBps": 2500
  },
  "confidence": 0.82,
  "reasoning": "High utilization combined with growing queue signals LP liquidity pressure"
}
```

**Why consensus matters:** The AI call uses `consensusIdenticalAggregation`. This means every DON node independently calls the AI endpoint and all must receive the same structured response. No single node can inject a false recommendation. The AI endpoint is engineered for deterministic JSON output to enable this consensus.

**Cost:** ~$0.001-0.003 per analysis call (Claude Haiku). Free contract reads.

### Workflow 3: Queue Monitor (every 15 minutes)

Watches the FIFO redemption queue specifically:
- **Queue depth:** how many LPs are waiting
- **Coverage ratio:** can the vault fulfill all pending requests with current free liquidity?
- **Liquidity crunch detection:** coverage ratio below 1.0 means some LPs will wait longer

---

## Composite Intelligence

After all three workflows run, a composite script cross-correlates the data.

**Why this matters:**

Individual workflows see individual slices:
- Vault Health sees: utilization at 75% (warning level)
- Queue Monitor sees: 8 pending redemptions (warning level)
- AI Advisor sees: "reduce utilization cap" with 0.85 confidence

No single metric is critical. But the combination tells a story: LPs are trying to exit, utilization is climbing, and the AI sees the trend accelerating.

**The composite layer surfaces this cascade before any individual monitor would escalate.**

The composite assessment gets its own on-chain proof, tagged `bridge-composite:critical`.

---

## The Proof Model

### Why Proofs?

Monitoring data is useful. But how do you know it's real? How do you prove that the vault was healthy on March 1st? Or that the AI recommended lowering the utilization cap on March 2nd?

On-chain proofs solve this. Every workflow run produces a `keccak256` hash of its metrics, written permanently to a smart contract on Sepolia.

### How It Works

1. **Read** contract state via CRE EVMClient (real Ethereum mainnet data)
2. **Compute** risk classification and key metrics
3. **Encode** metrics in deterministic ABI format: `abi.encode(timestamp, workflow, risk, metric1, metric2, ...)`
4. **Hash** the encoded bytes: `keccak256(encoded)` produces a 32-byte fingerprint
5. **Write** the hash + risk level to `SentinelRegistry.recordHealth()` on Sepolia
6. **Verify** anyone can re-run the workflow, encode the same fields, hash them, and compare

### Per-Workflow Proof Fields

| Workflow | Encoded Fields |
|----------|---------------|
| **vault-health** | timestamp, "vault-health", risk, utilBps, totalAssets, freeLiq, queueDepth, reserveRatio, sharePrice |
| **bridge-advisor** | timestamp, "bridge-advisor", risk, utilBps, queueDepth, confidence |
| **queue-monitor** | timestamp, "queue-monitor", risk, queueDepth, coverageRatio, utilBps |
| **bridge-composite** | timestamp, "bridge-composite", risk, utilBps, queueDepth, confidence |

### Risk Level Tags

Each proof is prefixed with its source:
- `vault:ok`, `vault:warning`, `vault:critical`
- `advisor:ok`, `advisor:warning`, `advisor:critical`
- `queue:ok`, `queue:warning`, `queue:critical`
- `bridge-composite:ok`, `bridge-composite:warning`, `bridge-composite:critical`

This makes on-chain records self-describing: you can query the contract and immediately know which workflow produced each assessment.

---

## Settlement Security

The vault uses Chainlink CCIP for settlement. The settlement adapter has three security layers:

### Layer 1: Source Allowlist
Only registered `(chainSelector, sender)` pairs are accepted. A message from an unregistered chain or sender is rejected.

### Layer 2: Replay Protection
A 3-tuple key `keccak256(sourceChainSelector, sender, messageId)` prevents the same settlement from being processed twice.

### Layer 3: Payload Domain Binding
Every settlement message includes `version`, `targetVault`, and `chainId`. The adapter verifies all three match before processing. This prevents cross-chain confusion (a message meant for chain A being replayed on chain B).

If `_ccipReceive` reverts, all state changes roll back atomically. The CCIP Router marks the message as FAILED, and manual re-execution is available via CCIP Explorer.

---

## Roles

| Role | Who | What They Can Do |
|------|-----|-----------------|
| **Default Admin** | Protocol multisig | Manage roles (2-step transfer with timelock) |
| **Governance** | DAO / multisig | Set policy parameters, register adapters, claim fees, emergency release |
| **Operations** | Keeper bot | Reserve liquidity, execute fills, process redemption queue |
| **Pauser** | Emergency responder | Pause/unpause (global, deposits only, reserves only) |
| **Settlement** | Adapter contract only | Reconcile settlements (success or loss) |

---

## Summary

| Layer | What | How |
|-------|------|-----|
| **Vault** | ERC-4626 with 5-bucket accounting | Solidity 0.8.24, OpenZeppelin 5.0.2 |
| **Settlement** | Chainlink CCIP canonical messages | LaneSettlementAdapter with 3-layer security |
| **Monitoring** | 3 CRE workflows (health, AI advisor, queue) | CRE SDK, EVMClient, HTTPClient, CronCapability |
| **AI** | Policy optimization recommendations | Claude Haiku via consensusIdenticalAggregation |
| **Proofs** | keccak256 hashes on Sepolia | SentinelRegistry.recordHealth() |
| **Composite** | Cross-workflow risk correlation | Cascade detection across all 3 workflows |
| **Security** | 83 tests, 4.16M fuzz assertions, triple audit | Foundry, 10K fuzz iterations |

The core innovation: **a bridge vault that doesn't just hold money, it actively monitors itself, gets AI recommendations, and proves every assessment on-chain.**
