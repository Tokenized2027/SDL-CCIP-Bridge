# SDL CCIP Bridge: Verification Guide

## What the On-Chain Proofs Prove

Every CRE workflow run produces a **keccak256 hash** that is written to the [SentinelRegistry contract on Sepolia](https://sepolia.etherscan.io/address/0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40).

Each record proves:

1. **Data integrity:** The hash is a deterministic fingerprint of the exact metrics observed. If any value changes, the hash is completely different.
2. **Temporal ordering:** Sepolia block timestamps provide an unforgeable record of *when* each health assessment was made.
3. **Risk classification:** The risk level string (e.g., `vault:critical`, `advisor:warning`) is stored in plaintext, creating a queryable history of vault health.

## How Hashing Works

Each workflow encodes its key metrics using Solidity ABI encoding, then computes `keccak256` of the result.

### Example: Vault Health Workflow

```
ABI-encode(
  uint256 timestamp,      // Unix seconds
  string  workflow,       // "vault-health"
  string  risk,           // "ok" | "warning" | "critical"
  uint256 utilBps,        // Utilization in basis points
  uint256 totalAssets,    // Total vault assets (raw wei)
  uint256 freeLiq,        // Free liquidity (raw wei)
  uint256 queueDepth,     // Number of pending redemptions
  uint256 reserveRatio,   // Bad debt reserve ratio (multiplied by 10^6)
  uint256 sharePrice      // Share price (multiplied by 10^6)
)
-> keccak256(encoded_bytes)
-> bytes32 snapshotHash
```

### Per-Workflow Fields

| Workflow | Encoded Fields |
|----------|---------------|
| **vault-health** | timestamp, workflow, risk, utilBps, totalAssets, freeLiq, queueDepth, reserveRatio (x10^6), sharePrice (x10^6) |
| **bridge-advisor** | timestamp, workflow, risk, utilBps, queueDepth, confidence (x10^6) |
| **queue-monitor** | timestamp, workflow, risk, queueDepth, coverageRatio (x10^6), utilBps |
| **bridge-composite** | timestamp, workflow, risk, utilBps, queueDepth, confidence (x10^6) |

All multipliers preserve decimal precision in `uint256` (Solidity has no floating-point numbers).

## How to Verify a Record

### Step 1: Get the snapshot data

Each workflow produces a JSON snapshot with `generated_at_utc` and the relevant metrics. These are stored in `intelligence/data/` after each workflow run.

### Step 2: Reproduce the hash

Using viem:

```javascript
import { keccak256, encodeAbiParameters, parseAbiParameters } from 'viem';

// Example: vault-health snapshot
const ts = BigInt(Math.floor(new Date('2026-03-03T14:30:00Z').getTime() / 1000));
const utilBps = BigInt(4500);                   // 45% utilization
const totalAssets = BigInt('1000000000000000000000000'); // 1M LINK in wei
const freeLiq = BigInt('550000000000000000000000');      // 550K LINK
const queueDepth = BigInt(3);
const reserveRatio = BigInt(50000);             // 0.05 * 10^6 = 5%
const sharePrice = BigInt(1002300);             // 1.0023 * 10^6

const encoded = encodeAbiParameters(
  parseAbiParameters(
    'uint256 ts, string wf, string risk, uint256 utilBps, uint256 totalAssets, uint256 freeLiq, uint256 queueDepth, uint256 reserveRatio, uint256 sharePrice'
  ),
  [ts, 'vault-health', 'ok', utilBps, totalAssets, freeLiq, queueDepth, reserveRatio, sharePrice],
);

const hash = keccak256(encoded);
console.log('Computed hash:', hash);
// Compare with the snapshotHash in the HealthRecorded event
```

### Step 3: Check on-chain

Query the `HealthRecorded` events on the SentinelRegistry contract:

```javascript
import { createPublicClient, http } from 'viem';
import { sepolia } from 'viem/chains';

const client = createPublicClient({ chain: sepolia, transport: http() });

const logs = await client.getLogs({
  address: '0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40',
  event: {
    type: 'event',
    name: 'HealthRecorded',
    inputs: [
      { name: 'snapshotHash', type: 'bytes32', indexed: true },
      { name: 'riskLevel', type: 'string' },
      { name: 'timestamp', type: 'uint256' },
    ],
  },
});

// Find matching hash
const match = logs.find(log => log.args.snapshotHash === hash);
if (match) {
  console.log('VERIFIED: Hash matches on-chain record');
  console.log('Risk level:', match.args.riskLevel);
  console.log('Block timestamp:', match.args.timestamp);
} else {
  console.log('NOT FOUND: Hash does not match any on-chain record');
}
```

If your computed hash matches a `snapshotHash` from the logs, the data is verified.

## Trust Model

### Current (Hackathon Demo)

```
CRE Workflow (local simulate)
       |
  Snapshot JSON (real mainnet vault data)
       |
  keccak256 hash
       |
  Single deployer key -> SentinelRegistry (Sepolia)
```

**Trust assumption:** The operator running the workflow simulation is honest. The contract reads are real (Ethereum mainnet via public RPCs), but a single key signs all proof transactions. The data is *verifiable* (anyone can recompute the hash from the same block state) but not yet *trustless* (you trust the operator didn't modify data before hashing).

### Production (DON Attestation)

```
CRE Workflow (Decentralized Oracle Network)
       |
  N independent oracle nodes execute the same workflow
       |
  Consensus on results (f+1 agreement)
       |
  Attested proof -> On-chain (trustless)
```

**Trust assumption:** Chainlink's DON provides Byzantine fault tolerance. No single party can fabricate results. The observation, computation, and attestation are all decentralized.

### What CRE Adds Over a Simple Hash

The value isn't just the hashing (you could hash data without CRE). CRE provides:

1. **Standardized workflow format:** Portable, auditable workflow definitions (YAML + TypeScript)
2. **Built-in capabilities:** EVMClient for contract reads, HTTPClient for API calls, CronCapability for scheduling
3. **Path to decentralization:** Same workflow code runs locally in `simulate` mode and on the DON in production
4. **AI consensus:** `consensusIdenticalAggregation` ensures all nodes agree on the same AI recommendation before it's accepted
5. **Chain-agnostic networking:** Read from Ethereum mainnet, write to Sepolia, in a single workflow execution

## Contract Details

| Field | Value |
|-------|-------|
| Contract | `SentinelRegistry` (shared with Orbital Sentinel) |
| Address | `0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40` |
| Network | Sepolia Testnet |
| Solidity | 0.8.19 |
| Key Function | `recordHealth(bytes32 snapshotHash, string riskLevel)` |
| Event | `HealthRecorded(bytes32 indexed snapshotHash, string riskLevel, uint256 timestamp)` |
| Views | `count()`, `latest()`, `recorded(uint256 index)` |
| Access | Owner-only `recordHealth` (Ownable2Step) |
| Deduplication | `mapping(bytes32 => bool)`, reverts `AlreadyRecorded` on duplicates |
| Input validation | `EmptyRiskLevel` on empty string, `RiskLevelTooLong` on > 256 bytes |
| Etherscan | [View on Sepolia](https://sepolia.etherscan.io/address/0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40) |

## Risk Level Format

All risk levels use a `workflow:severity` prefix format:

```
vault:ok          vault:warning          vault:critical
advisor:ok        advisor:warning        advisor:critical
queue:ok          queue:warning          queue:critical
bridge-composite:ok  bridge-composite:warning  bridge-composite:critical
```

This makes on-chain records self-describing. You can filter by prefix to see all assessments from a specific workflow, or filter by suffix to find all critical events across the system.

## Staleness Protection

The proof recording script (`scripts/record-bridge-proofs.mjs`) enforces:

- **Deduplication:** The `generated_at_utc` timestamp of each snapshot is tracked. Unchanged snapshots are not re-committed.
- **On-chain dedup:** The SentinelRegistry's `AlreadyRecorded` check prevents the same hash from being written twice, even if the script attempts it.
- **Multi-RPC fallback:** Cycles through multiple Sepolia RPCs if any single one fails.
- **Non-zero exit only on total failure:** Partial success (some workflows written, some skipped) exits cleanly.
