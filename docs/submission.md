# SDL CCIP Bridge: Hackathon Submission

## Quick Info

| Field | Value |
|-------|-------|
| Project Name | SDL CCIP Bridge |
| Tagline | AI-powered ERC-4626 bridge vault with Chainlink CCIP settlement and autonomous CRE monitoring |
| Team Size | 1 |
| Prize Tracks | CRE & AI, DeFi & Tokenization |
| GitHub | https://github.com/Tokenized2027/SDL-CCIP-Bridge |
| Chainlink Usage | https://github.com/Tokenized2027/SDL-CCIP-Bridge/blob/main/CHAINLINK.md |
| Contract (Sepolia) | https://sepolia.etherscan.io/address/0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40 |

---

## Project Description

SDL CCIP Bridge is an AI-powered ERC-4626 LP vault for cross-chain bridge liquidity, combining Chainlink CCIP (settlement), CRE (autonomous monitoring), Data Feeds (pricing), and AI (policy optimization) in a single integrated system.

**The bridge vault (766 nSLOC, 83 tests, triple audit):**
- LPs deposit assets into an ERC-4626 vault and earn fees from bridge settlement activity
- Bonded solvers provide instant destination-chain fulfillment
- Chainlink CCIP provides canonical settlement with 3-layer security (source allowlist, replay protection, domain binding)
- 5-bucket liquidity accounting tracks every wei across free, reserved, in-flight, bad debt reserve, and protocol fees

**The AI monitoring layer (3 CRE workflows):**

1. **Vault Health Monitor** reads all 5 liquidity buckets, policy parameters, pause state, queue depth, and LINK/USD price via EVMClient. Classifies vault risk (`ok|warning|critical`) and writes keccak256 proof hash to SentinelRegistry on Sepolia.

2. **Bridge AI Advisor** reads vault state via EVMClient, then calls an AI analysis endpoint (GPT-5.3-Codex) via HTTPClient with `consensusIdenticalAggregation`. All DON nodes must agree on the AI response before it's accepted. The AI recommends policy parameter adjustments (utilization cap, reserve cut, hot reserve target).

3. **Queue Monitor** tracks the FIFO redemption queue depth, liquidity coverage ratio, and individual request wait times. Detects queue buildup and liquidity crunch scenarios before LPs get locked.

**Composite Intelligence (Phase 1.5):** After all 3 workflows complete, a cross-correlation script identifies ecosystem-level risks that no single workflow can see in isolation. High utilization alone might be fine, but high utilization + growing queue + AI advisor flagging = escalation.

Every workflow run produces an immutable on-chain proof: a `HealthRecorded` event on the SentinelRegistry contract (Sepolia), containing the keccak256 hash of workflow-specific metrics. Risk levels use prefixed format (`vault:ok`, `advisor:warning`, `queue:critical`) so each proof is tagged with its source.

---

## How We Built It

- **Solidity 0.8.24** (Foundry): ERC-4626 vault with OpenZeppelin 5.0.2, Chainlink CCIP 1.6.1
- **CRE TypeScript SDK** (`@chainlink/cre-sdk@^1.0.9`): all 3 workflows
- **EVMClient.callContract()**: 15+ vault contract reads per workflow run
- **Chainlink Data Feed**: LINK/USD via latestAnswer() for TVL calculation
- **HTTPClient + consensusIdenticalAggregation**: AI analysis with DON consensus
- **CronCapability**: autonomous 15-30 minute scheduling
- **getNetwork()**: chain selector resolution (mainnet reads + Sepolia writes)
- **GPT-5.3-Codex**: structured risk assessment via Flask endpoint
- **viem**: on-chain interaction library for proof hash computation

---

## What Makes It Unique

1. **CCIP + CRE integration**: the vault uses CCIP for settlement AND CRE for monitoring. Same Chainlink stack, end to end.
2. **AI-powered policy optimization**: the bridge-ai-advisor workflow is the first CRE workflow that uses AI to recommend on-chain governance parameter changes.
3. **Cross-workflow intelligence**: composite analysis catches risks that no single workflow can see.
4. **Production-grade contracts**: 766 nSLOC, 83 tests (including 8 full lifecycle E2E), 4.16M invariant assertions, triple security audit (initial + deep re-audit + CRE/AI audit).
5. **Verifiable AI decisions**: every AI recommendation is hashed and anchored on-chain via SentinelRegistry.

---

## Chainlink Products Used

| Product | Usage |
|---------|-------|
| CCIP | Core settlement layer (CCIPReceiver, source allowlist, replay protection, domain binding) |
| CRE SDK | All 3 workflow definitions (Runner, handler, CronCapability, EVMClient, HTTPClient) |
| EVMClient | 15+ mainnet contract reads per workflow (vault buckets, policy, queue, pause state) |
| Data Feeds | LINK/USD price oracle (AggregatorV3 latestAnswer) |
| HTTPClient | AI policy analysis with consensusIdenticalAggregation |
| CronCapability | Autonomous scheduling (15-30 min intervals, 7x/day unified cycle) |
| getNetwork() | Chain selector for mainnet reads + Sepolia writes |

---

## Challenges

- Designing CRE workflows that read complex multi-contract vault state (5 buckets + queue + policy) within a single workflow run
- Ensuring `consensusIdenticalAggregation` works with AI analysis responses (prompt engineering for deterministic output)
- Cross-correlating data across 3 independent workflows in the composite intelligence phase
- Balancing monitoring granularity with CRE execution costs (free reads, but API credits for AI)
