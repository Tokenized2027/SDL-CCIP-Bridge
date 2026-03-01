# SDL CCIP Bridge: Technical Whitepaper

**Version:** 1.0
**Date:** March 1, 2026
**Authors:** Orbital Engineering

---

## Abstract

The SDL CCIP Bridge is a non-upgradeable, audited smart contract system that provides liquidity infrastructure for cross-chain asset bridging using Chainlink CCIP as the canonical settlement layer. The system is built around an ERC-4626 compliant LP vault (`LaneVault4626`) that manages liquidity across five distinct accounting buckets, coupled with a settlement adapter (`LaneSettlementAdapter`) that receives and validates Chainlink CCIP messages. This paper details the system architecture, economic model, security properties, and operational lifecycle.

---

## 1. Introduction

### 1.1 Problem Statement

Cross-chain asset bridging faces three fundamental challenges:

1. **Liquidity fragmentation:** Bridge protocols require destination-chain liquidity that is typically locked in protocol-owned pools, creating capital inefficiency and centralization risk.

2. **Settlement latency:** Canonical cross-chain messaging (e.g., optimistic rollup finality) can take minutes to hours, creating poor user experience for bridge transfers.

3. **Trust assumptions:** Most bridge designs require users to trust either a multisig, a relayer set, or an optimistic fraud-proof window. These introduce systemic risk that has historically resulted in billions of dollars in bridge exploits.

### 1.2 Solution

The SDL CCIP Bridge addresses these challenges through a three-party architecture:

- **Liquidity Providers (LPs)** deposit assets into an ERC-4626 vault, earning fees from bridge settlement activity without managing bridge operations directly.

- **Bonded Solvers** provide instant destination-chain fulfillment using their own capital, then are reimbursed (with fees) once the canonical settlement message arrives.

- **Chainlink CCIP** provides the canonical settlement layer, eliminating the need for custom relayer sets or optimistic fraud proofs. CCIP messages are the sole mechanism for settlement reconciliation.

This separation of concerns creates a system where LPs bear liquidity risk (managed by the vault's accounting model), solvers bear execution risk (managed by bonding and slashing), and neither party bears messaging risk (delegated to Chainlink CCIP).

---

## 2. System Architecture

### 2.1 Contract Overview

The system consists of four Solidity contracts:

```
+------------------------------------------+
|           LaneVault4626 (616 LOC)         |
|                                           |
|  ERC-4626 vault with:                     |
|  - 5-bucket liquidity accounting          |
|  - Dual state machines (routes + fills)   |
|  - FIFO redemption queue                  |
|  - Role-based access control              |
|  - Transfer allowlist (launch phase)      |
|  - Emergency release (72h timelock)       |
+----+-----+--------+----------------------+
     |     |        |
     |     |        |  SETTLEMENT_ROLE
     |     |        v
     |     |   +----+-------------------------+
     |     |   | LaneSettlementAdapter (105)   |
     |     |   |                               |
     |     |   |  CCIP receiver with:          |
     |     |   |  - Source allowlist            |
     |     |   |  - 3-tuple replay protection   |
     |     |   |  - Payload domain binding      |
     |     |   +-------------------------------+
     |     |
     |     |  Vault-only access
     |     v
     |   +-----------------------------+
     |   | LaneQueueManager (92)       |
     |   |                             |
     |   |  Strict FIFO queue:         |
     |   |  - Non-cancelable           |
     |   |  - Append/dequeue only      |
     |   +-----------------------------+
     |
     |  Off-chain simulation
     v
   +-----------------------------+
   | LaneVaultScaffold (228)     |
   |                             |
   | Python model parity:        |
   | - USD-denominated           |
   | - No token transfers        |
   +-----------------------------+
```

### 2.2 Non-Upgradeability

All contracts are deployed as immutable implementations without proxy patterns. This is a deliberate design choice:

- **No admin key can alter contract logic** after deployment
- **No storage layout vulnerabilities** from proxy upgrade collisions
- **Simpler security model** -- what you audit is what runs forever
- **Trade-off:** Bug fixes require deploying new contracts and migrating state. This is acceptable given the scope of the contracts (~800 nSLOC) and the thoroughness of the audit suite.

---

## 3. Liquidity Accounting Model

### 3.1 Five-Bucket Architecture

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
|  | (loss buffer     |  | Accrued          |                       |
|  |  from fee cuts)  |  | (governance-     |                       |
|  |                  |  |  claimable)      |                       |
|  +------------------+  +------------------+                       |
+-------------------------------------------------------------------+
```

**Key properties:**

1. **No commingling:** Each asset unit exists in exactly one bucket at any time.
2. **Conservation:** Every state transition moves assets between buckets with exact arithmetic (no rounding in bucket transitions).
3. **LP NAV exclusion:** `totalAssets()` returns `free + reserved + inFlight - protocolFees`, ensuring protocol fees are excluded from LP share pricing immediately upon accrual.

### 3.2 Accounting Invariants

Two invariants are checked inline after every state-mutating function via `_assertAccountingInvariants()`:

```solidity
require(badDebtReserveAssets <= freeLiquidityAssets);
require(protocolFeeAccruedAssets <= freeLiquidityAssets);
```

These ensure that the bad debt reserve and protocol fee accruals never exceed the free liquidity bucket, which would indicate a logical inconsistency in the settlement accounting.

A third invariant is verified in the test suite:

```
freeLiquidityAssets + reservedLiquidityAssets + inFlightLiquidityAssets
  >= protocolFeeAccruedAssets + badDebtReserveAssets
```

### 3.3 Phantom Asset Prevention

Settlement success credits fee income to the LP NAV. To prevent crediting phantom assets (fees claimed without actual token arrival), the `reconcileSettlementSuccess` function verifies the vault's actual token balance:

```solidity
uint256 requiredBalance = currentHeld + netFeeIncomeAssets;
uint256 actualBalance = IERC20(asset()).balanceOf(address(this));
if (actualBalance < requiredBalance) revert BalanceDeficit(requiredBalance, actualBalance);
```

This check runs before any accounting updates, ensuring that fee income tokens have actually been transferred to the vault before they are reflected in LP share pricing.

---

## 4. Bridge Lifecycle

### 4.1 Route and Fill State Machines

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

### 4.2 Lifecycle Flow

1. **Reserve** (`OPS_ROLE`): Operator identifies a bridge intent and reserves `amount` assets from free liquidity for `routeId` with an `expiry` timestamp. Utilization cap is enforced.

2. **Fill** (`OPS_ROLE`): Solver provides destination-chain fulfillment. Operator moves `amount` from reserved to in-flight for `fillId`.

3. **Settle** (`SETTLEMENT_ROLE`): CCIP message arrives at the adapter, is validated, and calls either:
   - `reconcileSettlementSuccess(fillId, principal, netFeeIncome)` -- returns principal to free liquidity, distributes fee income across LP yield, bad debt reserve, and protocol fee
   - `reconcileSettlementLoss(fillId, principal, recovered)` -- returns recovered amount to free, absorbs loss via bad debt reserve (uncovered loss hits LP NAV)

4. **Emergency Release** (`GOVERNANCE_ROLE`): If a fill is stuck in `Executed` state for longer than `emergencyReleaseDelay` (default 72 hours), governance can release it via `emergencyReleaseFill`. This treats the stuck fill as a loss, absorbing via the bad debt reserve.

### 4.3 Reservation Expiry

Reservations include an `expiry` timestamp. After expiry, anyone can call `expireReservation(routeId)` to release the locked liquidity back to free. This is **permissionless** -- no role is required. This prevents operator negligence from indefinitely locking LP funds.

---

## 5. LP Experience

### 5.1 ERC-4626 Compliance

The vault implements the full ERC-4626 standard for tokenized vaults:

- `deposit(assets, receiver)` / `mint(shares, receiver)` -- deposit assets, receive share tokens
- `withdraw(assets, receiver, owner)` / `redeem(shares, receiver, owner)` -- withdraw from free liquidity
- `maxDeposit()` / `maxMint()` -- returns 0 when paused (ERC-4626 spec compliance)
- `maxWithdraw(owner)` / `maxRedeem(owner)` -- bounded by available free liquidity
- `totalAssets()` -- LP NAV excluding protocol fees
- `convertToShares()` / `convertToAssets()` -- share-asset conversion with OZ rounding

### 5.2 Inflation Attack Protection

The vault uses a virtual decimals offset of 3 (`_decimalsOffset() = 3`), creating a 1000:1 share-to-asset multiplier. This makes first-depositor inflation attacks economically unviable. An attacker would need to donate 1000x the expected profit to manipulate the exchange rate by 1 share, far exceeding any reasonable attack budget.

### 5.3 FIFO Redemption Queue

When free liquidity is insufficient for a full withdrawal, LPs can use `requestRedeem(shares, receiver, owner)` to join a strict FIFO queue:

1. Shares are **escrowed** in the vault (transferred from owner to vault contract)
2. Request is **non-cancelable** once enqueued (policy: `no_cancel_once_enqueued`)
3. `OPS_ROLE` calls `processRedeemQueue(maxRequests)` to process pending requests as free liquidity becomes available
4. Each request is processed at the **current exchange rate** at processing time (not request time)
5. Processing stops when free liquidity is insufficient for the next request

**Queue properties:**
- O(1) enqueue and dequeue operations
- No priority lanes -- strict FIFO ordering
- Request IDs reset when queue empties (within-cycle uniqueness only)

### 5.4 Transfer Allowlist

During the launch phase, share token transfers are restricted to allowlisted addresses. This prevents secondary market trading before the vault's economic parameters are proven.

Governance can:
- Add/remove addresses from the allowlist
- Permanently disable the allowlist once the vault is mature

Mint, burn, and vault-internal transfers (escrow) are always exempt from the allowlist.

---

## 6. Fee Economics

### 6.1 Fee Distribution

When a bridge fill settles successfully, the `netFeeIncome` (fee charged to the bridge user, minus solver costs) is distributed across three recipients:

```
netFeeIncome
  |
  +-- badDebtReserveCutBps (default 10%) --> badDebtReserveAssets
  |
  +-- protocolFeeBps (default 0%)        --> protocolFeeAccruedAssets
  |
  +-- remainder                          --> freeLiquidityAssets (accrues to LP NAV)
```

### 6.2 Bad Debt Reserve

The bad debt reserve is a self-funding loss buffer:

- **Funded by:** A percentage cut of every successful settlement's fee income
- **Used when:** A settlement resolves as a loss (`reconcileSettlementLoss`). The reserve absorbs the loss up to its current balance.
- **Shortfall:** Any loss exceeding the reserve directly reduces `freeLiquidityAssets`, diluting LP NAV.

This creates a natural insurance mechanism where high-volume, successful bridge activity builds up a reserve that protects LPs during rare loss events.

### 6.3 Protocol Fee Safety Rail

The protocol fee has a hard cap (`protocolFeeCapBps`, default 10%). If governance attempts to set `protocolFeeBps` above the cap, the value is silently set to 0 as a fail-safe. This prevents governance from extracting excessive fees.

### 6.4 Fee Claim

Governance can claim accrued protocol fees via `claimProtocolFees(to, amount)`. The claim is bounded by both `protocolFeeAccruedAssets` and `freeLiquidityAssets`, ensuring claims don't overdraw the vault.

---

## 7. Settlement Adapter

### 7.1 CCIP Integration

The `LaneSettlementAdapter` extends Chainlink's `CCIPReceiver` base contract. It receives CCIP messages from registered source chains and translates them into vault settlement calls.

### 7.2 Security Model

Three layers of validation protect against malicious or malformed settlement messages:

**Layer 1 -- Source Allowlist:**
```solidity
if (!isAllowedSource[message.sourceChainSelector][sourceSender])
    revert SourceNotAllowed();
```
Only registered `(chainSelector, sender)` pairs are accepted. This prevents messages from unauthorized chains or contracts.

**Layer 2 -- Replay Protection:**
```solidity
bytes32 replayKey = keccak256(abi.encode(sourceChainSelector, sourceSender, messageId));
if (replayConsumed[replayKey]) revert ReplayDetected(replayKey);
replayConsumed[replayKey] = true;
```
Each message is uniquely identified by a 3-tuple. The adapter tracks consumed messages and rejects duplicates. This prevents double-settlement attacks.

**Layer 3 -- Payload Domain Binding:**
```solidity
if (payload.version != PAYLOAD_VERSION) revert InvalidPayload("invalid_version");
if (payload.targetVault != address(vault)) revert InvalidPayload("invalid_vault");
if (payload.chainId != block.chainid) revert InvalidPayload("invalid_chainid");
```
The payload itself contains redundant safety checks: protocol version, target vault address, and chain ID must all match. This prevents cross-chain replay attacks and message misrouting.

### 7.3 Settlement Payload

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

### 7.4 Revert Behavior

If `_ccipReceive` reverts for any reason (validation failure, vault revert), **all state changes are atomically rolled back**, including the replay key consumption. The CCIP Router marks the message as `FAILURE`. The message can be manually re-executed via the Chainlink CCIP Explorer once the root cause is resolved. No partial state corruption is possible.

---

## 8. Access Control

### 8.1 Role Hierarchy

```
DEFAULT_ADMIN_ROLE (timelock: configurable, default 2 days)
  |
  +-- GOVERNANCE_ROLE
  |     - setPolicy()
  |     - setSettlementAdapter()
  |     - setTransferAllowlist*()
  |     - claimProtocolFees()
  |     - emergencyReleaseFill()
  |     - setEmergencyReleaseDelay()
  |
  +-- OPS_ROLE
  |     - reserveLiquidity()
  |     - releaseReservation()
  |     - executeFill()
  |     - processRedeemQueue()
  |
  +-- PAUSER_ROLE
  |     - setPauseFlags()
  |
  +-- SETTLEMENT_ROLE (adapter-only)
        - reconcileSettlementSuccess()
        - reconcileSettlementLoss()
```

### 8.2 Admin Transfer

Admin role transfer uses OpenZeppelin's `AccessControlDefaultAdminRules`, which implements a 2-step transfer with configurable timelock:

1. Current admin calls `beginDefaultAdminTransfer(newAdmin)`
2. Timelock period elapses (configured at deployment)
3. New admin calls `acceptDefaultAdminTransfer()`

This prevents accidental admin transfers and provides a window for detection if the admin key is compromised.

### 8.3 Recommended Key Setup

| Role | Recommended Key Type |
|------|---------------------|
| `DEFAULT_ADMIN_ROLE` | Gnosis Safe multisig (3/6) with 2-day timelock |
| `GOVERNANCE_ROLE` | Gnosis Safe multisig (2/4) |
| `OPS_ROLE` | Hot wallet or automation (Chainlink Automation) |
| `PAUSER_ROLE` | EOA (for rapid emergency response) |
| `SETTLEMENT_ROLE` | Adapter contract only (never an EOA) |

---

## 9. Pause Mechanism

### 9.1 Granular Pauses

Three independent pause flags provide granular control:

| Flag | Scope | Operations Blocked |
|------|-------|--------------------|
| `globalPaused` | All operations | deposit, mint, withdraw, redeem, requestRedeem, processRedeemQueue, reserveLiquidity, releaseReservation, executeFill, reconcileSettlement*, claimProtocolFees |
| `depositPaused` | Deposits only | deposit, mint |
| `reservePaused` | Bridge operations | reserveLiquidity, releaseReservation, executeFill |

**Note:** `expireReservation()` is NOT affected by any pause flag -- it's always available to prevent permanent liquidity lockup.

### 9.2 Deployment State

The deployment script deploys the vault in **fully paused state** (all three flags set to `true`). This ensures no operations can occur until the operator has:
1. Configured the settlement adapter
2. Set the CCIP source allowlist
3. Configured policy parameters
4. Explicitly unpaused the desired operations

---

## 10. Gas Analysis

### 10.1 Core Operations

| Operation | Estimated Gas | Notes |
|-----------|--------------|-------|
| `deposit` | ~85K | ERC-4626 standard + bucket accounting |
| `withdraw` | ~80K | ERC-4626 standard + bucket accounting |
| `requestRedeem` | ~95K | Transfer to escrow + queue enqueue |
| `processRedeemQueue` (per item) | ~85K | Burn + transfer + dequeue per request |
| `reserveLiquidity` | ~70K | Bucket transition + utilization check |
| `executeFill` | ~65K | Two bucket transitions + two state updates |
| `reconcileSettlementSuccess` | ~90K | Balance check + bucket transition + fee distribution |
| `reconcileSettlementLoss` | ~75K | Bucket transition + reserve absorption |

### 10.2 Queue Processing Limits

| Batch Size | Total Gas | % of Block Limit |
|------------|-----------|-------------------|
| 1 | ~85K | 0.3% |
| 100 | ~8.5M | 28% |
| 350 | ~29.75M | 99% |

The `maxRequests` parameter bounds gas consumption per transaction. At 85K gas per queue item, approximately 350 items can be processed per block.

### 10.3 Queue Griefing Economics

An attacker creating many small (1-share) redemption requests would spend ~80K gas per request to create, while the protocol spends ~85K per request to process. **The attacker burns more gas than the protocol**, making queue griefing economically unviable.

---

## 11. Security Audit Summary

### 11.1 Audit Methodology

The contract system underwent two independent audit passes:

1. **9-Phase Methodology Audit** (March 1, 2026): Threat modeling, manual line-by-line review, static analysis (Slither v0.11.5, Aderyn v0.6.8), fix verification, invariant testing, attack scenario testing, 10,000-iteration fuzz campaign, and comprehensive reporting.

2. **Deep Re-Audit** (March 1, 2026): Cross-system cascade analysis (shared dependency risks with the broader Orbital ecosystem), EVM edge case review (PUSH0, transient storage, stack depth), gas griefing economics, and formal verification of pure math functions.

### 11.2 Findings Summary

| Severity | Count | Fixed | Acknowledged |
|----------|-------|-------|------------|
| Critical | 0 | -- | -- |
| High | 0 | -- | -- |
| Medium | 2 | 1 | 1 |
| Low | 3 | 3 | 0 |
| Informational | 3 | 0 | 3 |

**All medium and fixable low findings have been remediated.** See `docs/AUDIT-REPORT.md` and `docs/DEEP-AUDIT-REPORT.md` for full details.

### 11.3 Test Coverage

- 50 tests across 8 test files
- 10,000 fuzz iterations per fuzz test (audit-grade)
- 480,000 action sequences in invariant fuzz
- 4.16 million invariant assertions
- Static analysis: Slither + Aderyn (all findings triaged as false positives)

---

## 12. Deployment Checklist

### Pre-Deployment

- [ ] Run full test suite: `forge test --fuzz-runs 10000`
- [ ] Verify Solc version matches: `0.8.24`
- [ ] Verify OZ dependency version: `5.0.2`
- [ ] Prepare Gnosis Safe multisig for admin roles
- [ ] Confirm CCIP Router address for target chain

### Deployment

1. Deploy `LaneVault4626` with asset, name, symbol, admin delay, and initial admin
2. Deploy `LaneSettlementAdapter` with CCIP router and vault address
3. Register adapter via `vault.setSettlementAdapter(adapter)`
4. Vault deploys in paused state (all flags true)

### Post-Deployment

- [ ] Configure CCIP source allowlist via `adapter.setAllowedSource()`
- [ ] Set policy parameters via `vault.setPolicy()`
- [ ] Set emergency release delay if non-default
- [ ] Configure transfer allowlist for initial LPs
- [ ] Set up monitoring for `SettlementSuccess`, `SettlementLoss`, and `EmergencyFillReleased` events
- [ ] Unpause operations via `vault.setPauseFlags(false, false, false)`

---

## 13. Future Considerations

### 13.1 Multi-Lane Support

The current design supports one lane (source-destination pair) per vault deployment. Multi-lane support would require either:
- Multiple vault deployments (recommended -- simpler, isolated risk)
- A multi-lane extension with per-lane accounting (more capital efficient, higher complexity)

### 13.2 Automated Queue Processing

Redemption queue processing is currently manual (`OPS_ROLE` calls `processRedeemQueue`). Integration with Chainlink Automation would enable automatic queue processing when free liquidity becomes available.

### 13.3 Dynamic Fee Pricing

The current fee structure is static (fixed BPS parameters). Future iterations could implement dynamic fee pricing based on utilization, volatility, or cross-chain gas costs.

---

## Appendix A: Settlement Payload Encoding

The settlement payload is ABI-encoded using Solidity's standard `abi.encode`:

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

The adapter decodes this with `abi.decode(message.data, (SettlementPayload))`.

## Appendix B: ERC-4626 Rounding Behavior

OpenZeppelin 5.0.2 implements conservative rounding:

| Function | Rounds | Direction | Effect |
|----------|--------|-----------|--------|
| `convertToShares(assets)` | Down | Fewer shares per asset | Favors vault |
| `convertToAssets(shares)` | Down | Fewer assets per share | Favors vault |
| `previewDeposit(assets)` | Down | LP gets fewer shares | Favors vault |
| `previewMint(shares)` | Up | LP pays more assets | Favors vault |
| `previewWithdraw(assets)` | Up | LP burns more shares | Favors vault |
| `previewRedeem(shares)` | Down | LP gets fewer assets | Favors vault |

Combined with the 1000:1 virtual offset, this rounding behavior makes share price manipulation economically meaningless.

---

*This whitepaper describes the SDL CCIP Bridge as deployed. The contracts are non-upgradeable -- the behavior described here is permanent and immutable once deployed.*
