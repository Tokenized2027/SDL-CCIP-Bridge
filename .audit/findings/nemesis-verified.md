# Nemesis Audit Report: SDL-CCIP-Bridge

**Target**: `/home/avi/projects/SDL-CCIP-Bridge/`
**Auditor**: Nemesis Deep-Logic Security Audit Agent
**Date**: 2026-03-07
**Methodology**: Iterative Dual-Loop (Feynman Interrogation + State Inconsistency Analysis)
**Passes**: 4 Feynman/State iterations until convergence

---

## Scope

| Contract | LOC | Role | Deployed |
|---|---|---|---|
| `src/LaneVault4626.sol` | 617 | Core ERC-4626 vault with 5-bucket accounting | YES (Sepolia) |
| `src/LaneQueueManager.sol` | 91 | FIFO redemption queue | YES (Sepolia) |
| `src/LaneSettlementAdapter.sol` | 104 | CCIP receiver with replay protection | YES (Sepolia) |
| `src/LaneVaultScaffold.sol` | 227 | Simulation scaffold | NO (not deployed) |

**Dependencies**: OpenZeppelin 5.0.2, Chainlink CCIP 1.6.1

**Excluded from scope**: Test files, scripts, workflows, platform, docs.

---

## Nemesis Map

### Attacker Model
1. External attacker (no roles) -- can only call public/external functions
2. Compromised OPS_ROLE -- can reserve, fill, process queue
3. Compromised SETTLEMENT_ROLE -- can call reconcile functions
4. Compromised GOVERNANCE_ROLE -- can change policy, adapter, fees, emergency release
5. Cross-chain attacker -- sends malicious CCIP messages

### Attack Surface
- ERC-4626 deposit/withdraw/redeem (public)
- requestRedeem + processRedeemQueue (public + OPS)
- Bridge lifecycle: reserve -> fill -> settle (OPS + SETTLEMENT)
- CCIP message ingestion (via Chainlink Router)
- Policy and configuration changes (GOVERNANCE)

### Discovery Methodology
- Phase 0: Attacker recon (5 questions)
- Phase 1: Function-state matrix + coupled dependency map + cross-reference
- Phase 2: Feynman interrogation (7 categories x every function)
- Phase 3: State mutation matrix + parallel path comparison + ordering analysis
- Phase 4: Feedback loop (4 iterations to convergence)
- Phase 5: Multi-transaction adversarial journey tracing (8 sequences)
- Phase 6: Verification gate (code trace for every finding)

---

## Verification Summary

| Category | Count |
|---|---|
| Total functions analyzed | 28 (vault) + 6 (adapter) + 5 (queue) = 39 |
| Line-by-line verdicts issued | 39 SOUND, 3 SUSPECT (investigated), 0 VULNERABLE |
| Adversarial journeys traced | 8 |
| Findings investigated | 12 |
| True positives | 4 |
| False positives eliminated | 4 |
| Feedback loop iterations | 4 (converged) |

---

## VERIFIED FINDINGS

### M-01: Sub-Allocation Cumulative Overflow Locks LP Operations [MEDIUM]

**Discovery Path**: Cross-feed (Feynman Cat 4 assumptions + State mutation analysis)

**Location**: `LaneVault4626.sol` lines 195-201, 229-235, 479-487, 604-611

**Description**: The `_assertAccountingInvariants()` function validates `badDebtReserveAssets <= freeLiquidityAssets` and `protocolFeeAccruedAssets <= freeLiquidityAssets` individually, but does NOT validate their sum: `badDebtReserveAssets + protocolFeeAccruedAssets <= freeLiquidityAssets`. The `setPolicy()` function allows `badDebtReserveCutBps` and `protocolFeeBps` each up to 10000 (100%), with no constraint on their combined value.

When `badDebtReserveCutBps + protocolFeeBps > 10000` and settlements occur with non-zero fee income, the cumulative sub-allocations grow faster than `freeLiquidityAssets`. After enough settlements, `badDebtReserveAssets + protocolFeeAccruedAssets > freeLiquidityAssets`, causing `availableFreeLiquidityForLP()` to return 0.

**Impact**:
- LP withdrawals blocked (maxWithdraw/maxRedeem return 0)
- New bridge operations blocked (reserveLiquidity reverts)
- Queue processing blocked (insufficient available liquidity)
- `claimProtocolFees` does NOT recover available liquidity (decreases both numerator and denominator equally)
- Only recovery: a loss event draining `badDebtReserveAssets`, or governance policy change before next settlement

**Proof of Concept**:
```
Policy: cutBps=10000, feeBps=10000
5 settlements with principal=100, fee=200 each:
  After 5: free=2000, badDebt=1000, protocolFee=1000
  available = 2000 - 1000 - 1000 = 0 (LOCKED)
```

**Preconditions**:
1. Governance sets `badDebtReserveCutBps + protocolFeeBps > 10000`
2. Multiple settlements with non-zero fee income occur
3. No loss events drain badDebtReserve between settlements

**Recommendation**:
```solidity
// Option A: Constrain policy in setPolicy()
require(badDebtReserveCutBps_ + protocolFeeBps_ <= BPS_DENOMINATOR, "Combined BPS > 100%");

// Option B: Add sum check to _assertAccountingInvariants()
if (badDebtReserveAssets + protocolFeeAccruedAssets > freeLiquidityAssets) {
    revert InvariantViolation("combined_suballoc_exceeds_free");
}
```

---

### L-01: Fee-on-Transfer Token Incompatibility [LOW]

**Discovery Path**: Feynman-only (Cat 4 assumptions)

**Location**: `LaneVault4626.sol` lines 270-277 (deposit), 279-286 (mint)

**Description**: The `deposit` and `mint` functions credit `freeLiquidityAssets += assets` using the REQUESTED amount, not the actual amount received. If the underlying asset is a fee-on-transfer token, the vault's accounting will exceed its actual balance, creating phantom assets.

This is a standard limitation of the OpenZeppelin ERC-4626 implementation (which also does not handle fee-on-transfer tokens). The vault MUST be deployed with standard ERC-20 tokens only.

**Impact**: Progressive insolvency if used with fee-on-transfer tokens. Not relevant for the current deployment (uses LINK, a standard ERC-20).

**Preconditions**: Vault deployed with a fee-on-transfer or rebasing token.

**Recommendation**: Document in deployment checklist that ONLY standard ERC-20 tokens are supported. Optionally add a balance-before/after check in deposit/mint.

---

### L-02: Write-Only State Variables (Dead Storage) [LOW]

**Discovery Path**: State-only (Mutation matrix)

**Location**: `LaneVault4626.sol` lines 79, 98, 99

**Description**: Three state variables are written but never read by contract logic:
- `targetHotReserveBps` (line 79): Set in `setPolicy` (line 231), never enforced in any guard or check
- `settledFeesEarnedAssets` (line 98): Incremented in `reconcileSettlementSuccess` (line 488), never read
- `realizedNavLossAssets` (line 99): Incremented in `reconcileSettlementLoss` (line 519) and `emergencyReleaseFill` (line 569), never read

**Impact**: Minor gas waste (~20K per SSTORE). No security impact. These exist for off-chain monitoring.

**Recommendation**: Consider making these `public` with explicit documentation that they are monitoring-only. Alternatively, emit them in events only (saves SSTORE gas).

---

### L-03: Queue Request ID Reuse After Empty [LOW]

**Discovery Path**: Feynman-only (Cat 5 boundaries)

**Location**: `LaneQueueManager.sol` lines 63-78

**Description**: When the queue is fully drained (last dequeue), `headRequestId` and `tailRequestId` both reset to 0. The next `enqueue` produces `requestId = 1`, which was the ID of the very first request ever created. While the old request's data was deleted (`delete _requests[currentHead]` at line 68), off-chain systems tracking requests by ID may confuse old and new requests.

**Impact**: No on-chain security impact. Potential confusion for off-chain indexers.

**Recommendation**: Either document the ID reuse behavior for off-chain integrators, or use a monotonically increasing counter that never resets (change `requestId = tailRequestId + 1` to use a separate `nextRequestId` counter).

---

## FALSE POSITIVES ELIMINATED

| ID | Description | Reason Eliminated |
|---|---|---|
| F-02 | `redeem()` double-computes `previewRedeem` | Both calls occur in the same transaction under reentrancy guard. No state change between them. Values are identical. |
| F-04 | `reconcileSettlementSuccess` balance check doesn't account for badDebt/protocolFee | These are sub-allocations of `freeLiquidityAssets`, not additional tokens. `currentHeld = free + reserved + inFlight` already counts all real tokens. |
| F-06 | `emergencyReleaseFill` uint64 overflow in `readyAt` | `executedAt` (current timestamp ~1.7e9) + `emergencyReleaseDelay` (max uint48 ~2.8e14) = ~2.8e14, well within uint64 max (~1.8e19). |
| F-07 | CCIP message delivery reverts if vault is paused | Standard CCIP pattern. Revert = message retry. When vault unpauses, messages are redelivered. No permanent loss. |
| S-02 | Queue processing exchange rate drift | Maximum 1 wei per queue entry due to integer truncation. Not weaponizable (would cost attacker more gas than the drift is worth). Over 1M entries: drift = 1e-12 tokens. |
| Donation Attack | Direct token transfer inflates share price | `totalAssets()` uses virtual accounting (5 buckets), not `balanceOf`. Donations are dead tokens. |
| Double Settlement | Same fill settled twice | One-way state machine: fill status checked as Executed before any settlement. Terminal states (SettledSuccess/SettledLoss) prevent re-settlement. |
| CCIP Replay | Replayed CCIP message double-credits | Two-layer defense: adapter replay key (source+sender+messageId) + vault state machine finality. |
| Privilege Escalation | Attacker gains SETTLEMENT_ROLE | Even with SETTLEMENT_ROLE, phantom asset inflation is blocked by the balance check in `reconcileSettlementSuccess`. Attacker must actually send tokens. |

---

## Architecture Assessment

### Strengths
1. **Virtual accounting**: The 5-bucket system completely decouples share price from actual token balance, preventing donation/inflation attacks.
2. **Dual state machine**: Route and Fill have independent one-way state machines with cross-reference validation, preventing double-settlement and state confusion.
3. **Balance check on success settlement**: Line 474-477 prevents phantom asset inflation even with a compromised settlement adapter.
4. **CCIP triple validation**: Source allowlist + replay protection + domain/version binding provides defense-in-depth for cross-chain messages.
5. **Reentrancy protection**: Every state-changing function has `nonReentrant`.
6. **Accounting invariants checked after every mutation**: `_assertAccountingInvariants()` called in every state-changing function.
7. **ERC-4626 inflation attack mitigation**: `_decimalsOffset = 3` makes first-depositor manipulation uneconomical.
8. **Permissionless safety valves**: `expireReservation` allows anyone to clear expired reservations, preventing permanent liquidity locking.

### Design Considerations (Not Vulnerabilities)
1. **In-flight tokens never physically leave the vault**: The current architecture tracks in-flight amounts as an accounting entry. Actual cross-chain token transfer happens outside these contracts. If architecture evolves to move tokens, `reconcileSettlementLoss` would need a balance check.
2. **Queue processing rate drift**: ~1 wei per iteration, by design. Documented and tested.
3. **Policy changes take immediate effect for in-flight fills**: No time-locked policy changes. Governance trust assumption.
4. **Non-cancelable queue entries**: By design. Once shares are escrowed, there is no cancel path.

---

## Summary Statistics

| Severity | Count | Discovery Path |
|---|---|---|
| CRITICAL | 0 | -- |
| HIGH | 0 | -- |
| MEDIUM | 1 (M-01) | Cross-feed (Feynman + State) |
| LOW | 3 (L-01, L-02, L-03) | Feynman-only (2), State-only (1) |
| False Positives Eliminated | 9 | Various |

**Overall Assessment**: The SDL-CCIP-Bridge vault is well-designed with strong defense-in-depth. The virtual accounting model, dual state machines, balance checks, and CCIP validation layers provide robust protection against the major DeFi attack vectors (donation, inflation, replay, double-settlement, reentrancy). The single MEDIUM finding (M-01) is a governance configuration footgun that requires extreme policy settings and is easily mitigated with a single constraint check.
