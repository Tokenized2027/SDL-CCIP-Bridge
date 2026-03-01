# SDL CCIP Bridge

ERC-4626 LP vault with queue-based redemptions and Chainlink CCIP settlement for cross-chain bridge liquidity.

## Overview

The SDL CCIP Bridge is a non-upgradeable smart contract system that manages liquidity for cross-chain asset bridging using Chainlink's Cross-Chain Interoperability Protocol (CCIP). Liquidity providers deposit assets into an ERC-4626 vault and earn fees from bridge settlement activity. Bonded solvers provide instant destination-chain fulfillment, and CCIP canonical messages settle the accounting.

### How It Works

```
                          +-----------------+
  LP deposits ---------> |                 |
                          |  LaneVault4626  |  <--- ERC-4626 vault
  LP withdrawals <------- |   (5-bucket     |       Strict FIFO queue
                          |    accounting)  |       Transfer allowlist
                          +--------+--------+
                                   |
                    reserve / fill / settle
                                   |
                          +--------v--------+
                          |                 |
  CCIP Router ----------> | Settlement      |  <--- Chainlink CCIP receiver
                          |  Adapter        |       Source allowlist
                          |                 |       Replay protection
                          +-----------------+       Domain binding
```

1. **LPs deposit** assets (e.g., LINK) into the vault, receiving share tokens
2. **Operators reserve** liquidity for bridge routes (subject to utilization cap)
3. **Solvers execute fills** on the destination chain using reserved liquidity
4. **CCIP settlement messages** arrive via the adapter, reconciling success (fees distributed) or loss (bad debt reserve absorbs)
5. **LPs withdraw** from free liquidity, or join the FIFO redemption queue

## Contracts

| Contract | LOC | Description |
|----------|-----|-------------|
| [`LaneVault4626`](src/LaneVault4626.sol) | 616 | Core ERC-4626 vault with 5-bucket liquidity accounting, dual state machines, FIFO redemption queue, and role-based access control |
| [`LaneQueueManager`](src/LaneQueueManager.sol) | 91 | Immutable FIFO redemption queue with strict no-cancel policy |
| [`LaneSettlementAdapter`](src/LaneSettlementAdapter.sol) | 104 | Chainlink CCIP receiver with source allowlist, 3-tuple replay protection, and payload domain binding |
| [`LaneVaultScaffold`](src/LaneVaultScaffold.sol) | 227 | Off-chain simulation parity contract (mirrors Python invariant model, not deployed on-chain) |

## Architecture

### 5-Bucket Liquidity Model

All vault assets are tracked across five accounting buckets in asset units:

| Bucket | Description |
|--------|-------------|
| `freeLiquidityAssets` | Available for LP withdrawals and new bridge reservations |
| `reservedLiquidityAssets` | Locked for pending bridge routes (pre-fill) |
| `inFlightLiquidityAssets` | Locked during active CCIP settlement (post-fill) |
| `badDebtReserveAssets` | Loss buffer funded by a cut of settlement fee income |
| `protocolFeeAccruedAssets` | Governance-claimable protocol fees |

**Invariant:** `totalAssets() = free + reserved + inFlight - protocolFees`

### Dual State Machines

**Route lifecycle:**
```
None -> Reserved -> Released (early release by OPS)
                 -> Filled -> SettledSuccess
                           -> SettledLoss
```

**Fill lifecycle:**
```
None -> Executed -> SettledSuccess
                 -> SettledLoss
```

### Role-Based Access Control

| Role | Permissions |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Role management (2-step transfer with configurable timelock) |
| `GOVERNANCE_ROLE` | Policy updates, adapter registration, fee claims, emergency release, transfer allowlist |
| `OPS_ROLE` | Reserve/release liquidity, execute fills, process redemption queue |
| `PAUSER_ROLE` | Pause/unpause operations (global, deposit, reserve) |
| `SETTLEMENT_ROLE` | Settlement reconciliation (granted exclusively to the adapter) |

### Security Features

- **ERC-4626 inflation protection:** 1000:1 virtual decimals offset (`_decimalsOffset() = 3`)
- **Reentrancy guard:** On all state-mutating functions
- **Inline accounting invariants:** `_assertAccountingInvariants()` checked after every state change
- **Phantom asset prevention:** `reconcileSettlementSuccess` verifies actual token balance before crediting fees
- **Transfer allowlist:** Launch-phase restriction (can be permanently disabled)
- **Non-upgradeable:** Immutable deployment, no proxy pattern
- **2-step admin transfer:** Via `AccessControlDefaultAdminRules` with configurable timelock
- **Emergency release:** 72h default timelock for stuck in-flight fills
- **Permissionless expiry:** Anyone can release expired reservations

### Settlement Adapter Security

- **Source allowlist:** Only registered `(chainSelector, sender)` pairs accepted
- **3-tuple replay protection:** `keccak256(sourceChainSelector, sender, messageId)` prevents duplicate processing
- **Payload domain binding:** Validates `version`, `targetVault`, and `chainId` match
- **Atomic revert:** On `_ccipReceive` revert, CCIP Router marks message as FAILURE (manual re-execution via CCIP Explorer)

## Policy Parameters

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `badDebtReserveCutBps` | 1000 (10%) | 0-10000 | Percentage of fee income allocated to bad debt reserve |
| `maxUtilizationBps` | 6000 (60%) | 0-10000 | Maximum utilization cap for reserved + in-flight liquidity |
| `targetHotReserveBps` | 2000 (20%) | 0-10000 | Advisory hint for off-chain keeper (not enforced on-chain) |
| `protocolFeeBps` | 0 (0%) | 0-protocolFeeCapBps | Protocol fee percentage of settlement income |
| `protocolFeeCapBps` | 1000 (10%) | 0-10000 | Hard cap on protocol fee (governance safety rail) |
| `emergencyReleaseDelay` | 3 days | >= 1 day | Timelock before stuck fills can be emergency-released |

## Test Suite

**50 tests passing** across 8 test files, including fuzz, invariant, and attack scenario coverage.

| File | Tests | Category |
|------|-------|----------|
| `LaneVault4626.t.sol` | 8 | Core vault: deposits, queue, routes, roles, pauses |
| `LaneVault4626Fuzz.t.sol` | 4 | Fuzz: share conservation, FIFO fairness, settlement isolation |
| `LaneVault4626Invariant.t.sol` | 1 | 32-action state machine invariants |
| `LaneVault4626.EnhancedInvariants.t.sol` | 1 | 48-action fuzz with 6 invariants (solvency, shares, queue, fees, assets, accounting) |
| `LaneVault4626.Attacks.t.sol` | 14 | Attack scenarios: donation, reentrancy, replay, inflation, fake fills |
| `LaneSettlementAdapter.t.sol` | 6 | Adapter: source allowlist, replay, payload validation |
| `LaneVaultScaffold.t.sol` | 5 | Scaffold: reserve cap, fee splits, loss absorption |
| `DeepAudit.t.sol` | 11 | Deep audit: balance coverage, phantom assets, ERC-4626 compliance |

**Invariant coverage:** 4.16M assertions across 480K action sequences at audit-grade (10,000 fuzz runs).

## Security Audits

Two independent audits completed. See [`docs/AUDIT-REPORT.md`](docs/AUDIT-REPORT.md) and [`docs/DEEP-AUDIT-REPORT.md`](docs/DEEP-AUDIT-REPORT.md).

| Audit | Date | Findings | Status |
|-------|------|----------|--------|
| Phase 1 (9-phase methodology) | 2026-03-01 | 8 findings (2M, 3L, 3I) | All fixed or acknowledged |
| Deep re-audit (cross-system) | 2026-03-01 | 11 CCIP-specific checks | All 4 actionable findings fixed |

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) (forge, cast, anvil)

### Setup

```bash
git clone https://github.com/Tokenized2027/SDL-CCIP-Bridge.git
cd SDL-CCIP-Bridge
forge install
```

### Build

```bash
forge build
```

### Test

```bash
# Standard run
forge test -vv

# Audit-grade (10K fuzz iterations)
forge test --fuzz-runs 10000

# Gas report
forge test --gas-report

# Specific test file
forge test --match-path "test/LaneVault4626.t.sol" -vv
```

### Format

```bash
forge fmt --check
forge fmt           # auto-fix
```

### Deploy

```bash
# Set env vars
export ASSET_ADDRESS=0x...        # ERC-20 underlying (e.g., LINK)
export CCIP_ROUTER=0x...          # Chainlink CCIP Router
export INITIAL_ADMIN=0x...        # Admin address (use multisig)
export DEFAULT_ADMIN_DELAY=172800 # 2-day timelock

# Dry run
forge script script/Deploy.s.sol --rpc-url $RPC_URL

# Broadcast
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
```

The deployment script deploys both contracts **in paused state**. Operations must be explicitly unpaused after configuration is complete.

## Dependencies

| Package | Version | Usage |
|---------|---------|-------|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | 5.0.2 | ERC-4626, ERC-20, SafeERC20, AccessControlDefaultAdminRules, ReentrancyGuard |
| [Chainlink CCIP](https://github.com/smartcontractkit/chainlink-ccip) | 1.6.1 | CCIPReceiver, Client.Any2EVMMessage, IRouterClient |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std) | latest | Testing framework, deployment scripting |

## Chain Compatibility

Compiled with Solc 0.8.24 (emits `PUSH0`). Compatible with all Shanghai+ chains:

| Chain | PUSH0 | Status |
|-------|-------|--------|
| Ethereum Mainnet | Yes | Compatible |
| Arbitrum (Nitro) | Yes | Compatible |
| Optimism (Bedrock) | Yes | Compatible |
| Base (Bedrock) | Yes | Compatible |
| Sepolia | Yes | Compatible |

## License

MIT
