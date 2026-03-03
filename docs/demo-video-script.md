# Demo Video Script: SDL CCIP Bridge

**Format:** Screen recording with voiceover, 2 min 40 sec.
**Tone:** Conversational, authoritative, no jargon without explanation. Short sentences. One idea per line.
**Visuals:** [SHOW] tags indicate what's on screen. Voiceover text is everything else.

---

## Scene 1: The Problem (0:00 - 0:30)

[SHOW: Etherscan bridge contract page, or generic DeFi bridge interface]

Cross-chain bridges move billions.

But the vaults behind them? Most are black boxes.

An LP deposits into a vault.
A solver takes liquidity to fill a bridge.
The settlement message comes back via CCIP.

But what happens in between?

Utilization spikes. Redemption queues grow.
Bad debt accumulates. Policy parameters drift.

Nobody's watching the vault health continuously.
And when something goes wrong, it's already too late.

That's what we built the SDL CCIP Bridge to solve.

---

## Scene 2: What It Does (0:30 - 1:20)

[SHOW: Code editor open to LaneVault4626.sol, highlight 5-bucket state variables]

The core is an ERC-4626 vault.
LPs deposit assets and earn fees from bridge settlement activity.

But this isn't a simple deposit-withdraw vault.

It tracks every single wei across five accounting buckets:
free liquidity, reserved, in-flight, bad debt reserve, and protocol fees.

[SHOW: Architecture diagram from README or CRE-AI-ARCHITECTURE.md]

On top of the vault, we built three Chainlink CRE workflows.

CRE is Chainlink's Runtime Environment.
Think of it as a decentralized server
running across Chainlink's oracle network.

The first workflow reads all five liquidity buckets every 15 minutes.
Utilization, share price, pause state, queue depth.
It classifies the vault as OK, Warning, or Critical.

[SHOW: bridge_analyze_endpoint.py, highlight AI prompt]

The second is the AI advisor.
It reads the same vault state,
then sends it to a GPT-4o model via HTTPClient.

Here's the key: the AI call uses `consensusIdenticalAggregation`.
That means all DON nodes must get the same AI response
before accepting it.

The AI recommends policy parameter changes:
lower the utilization cap, increase the reserve cut,
adjust the hot reserve target.

[SHOW: Queue monitor workflow main.ts]

The third monitors the redemption queue.
How many LPs are waiting to withdraw?
Is there enough free liquidity to cover them?
It detects liquidity crunches before they happen.

---

## Scene 3: How It All Connects (1:20 - 2:10)

[SHOW: Sepolia Etherscan, SentinelRegistry contract, scroll HealthRecorded events]

Every workflow run produces an on-chain proof.

A keccak256 hash of the actual metrics,
written to a SentinelRegistry contract on Sepolia.

Each proof is tagged with its source:
"vault:ok", "advisor:warning", "queue:critical".

So you can query the contract
and get a permanent, tamper-proof history
of every health assessment ever made.

[SHOW: Composite intelligence diagram or script output]

But here's what makes it powerful.

After all three workflows complete,
a composite intelligence layer cross-correlates the data.

High utilization alone might be fine.
But high utilization, plus a growing queue,
plus the AI advisor flagging a risk?

That's a cascade. And the composite layer catches it
before any single monitor would.

And that composite assessment
also gets its own on-chain proof.

[SHOW: Forge test output, all 83 passing]

On the smart contract side,
83 tests passing.
Including 8 full lifecycle E2E tests,
15 advanced edge-case audits,
and over 4 million fuzz invariant assertions.

Triple security audit. All findings fixed.

---

## Scene 4: Wrap (2:10 - 2:40)

[SHOW: CHAINLINK.md or Chainlink product table]

SDL CCIP Bridge uses seven Chainlink products:

CCIP for settlement.
CRE SDK, EVMClient, HTTPClient, CronCapability
for autonomous monitoring.
Data Feeds for LINK/USD pricing.
And getNetwork for chain selector resolution.

All coordinated through one SentinelRegistry contract.

[SHOW: GitHub repo overview]

Built with Solidity, TypeScript, Python, and viem.
AI powered by GPT-4o.
766 lines of production Solidity. 83 tests. Triple audit.

This isn't just a bridge vault.
It's a bridge vault that watches itself.

Autonomous. AI-powered. Verifiable on-chain.

---

## Recording Notes

**Tabs to have open before recording:**
1. GitHub repo: `https://github.com/Tokenized2027/SDL-CCIP-Bridge`
2. Sepolia Etherscan: `https://sepolia.etherscan.io/address/0xE5B1b708b237F9F0F138DE7B03EEc1Eb1a871d40`
3. Code editor with `src/LaneVault4626.sol` open
4. Terminal with forge test output ready

**Pre-run checklist:**
- Run `forge test -vv` and save terminal output for recording
- Open CRE-AI-ARCHITECTURE.md for architecture diagram reference
- Have `platform/bridge_analyze_endpoint.py` open for AI prompt walkthrough
- Recent on-chain proofs visible on Etherscan

**Timing guide:**
- Scene 1 (Problem): ~30 seconds
- Scene 2 (What it does): ~50 seconds
- Scene 3 (How it connects): ~50 seconds
- Scene 4 (Wrap): ~30 seconds
- Total: ~2 min 40 sec

**Delivery tips:**
- Pause slightly between scenes for visual transitions
- Let the test output speak for itself (83 passed, 0 failed)
- Don't rush the AI consensus explanation, it's the differentiator
- End on the tagline: "a bridge vault that watches itself"
