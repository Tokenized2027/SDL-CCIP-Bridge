# Phase 6: Verification Gate

Every C/H/M finding verified via code trace. False positives eliminated.

---

## VERIFIED: M-01 -- Sub-allocation Cumulative Overflow

### Code Trace

**setPolicy** (line 222-238): `badDebtReserveCutBps` is clamped to [0, 10000]. `protocolFeeBps` is clamped to [0, 10000] but also must be <= `protocolFeeCapBps`. `protocolFeeCapBps` clamped to [0, 10000]. There is NO constraint that `badDebtReserveCutBps + protocolFeeBps <= 10000`.

**reconcileSettlementSuccess** (line 479-487):
```solidity
uint256 reserveCut = (netFeeIncomeAssets * badDebtReserveCutBps) / BPS_DENOMINATOR;
uint256 protocolFee = (netFeeIncomeAssets * protocolFeeBps) / BPS_DENOMINATOR;
// ...
badDebtReserveAssets += reserveCut;
protocolFeeAccruedAssets += protocolFee;
```

When `badDebtReserveCutBps = 10000` and `protocolFeeBps = 10000`:
- `reserveCut = netFeeIncome * 10000 / 10000 = netFeeIncome`
- `protocolFee = netFeeIncome * 10000 / 10000 = netFeeIncome`
- Total sub-allocation per settlement = `2 * netFeeIncome`
- But `freeLiquidity` only increases by `principal + netFeeIncome`

**_assertAccountingInvariants** (line 604-611):
```solidity
if (badDebtReserveAssets > freeLiquidityAssets) revert ...;
if (protocolFeeAccruedAssets > freeLiquidityAssets) revert ...;
```
Only checks INDIVIDUAL bounds. Does NOT check sum.

**availableFreeLiquidityForLP** (line 195-201):
```solidity
uint256 reserved = protocolFeeAccruedAssets + badDebtReserveAssets;
if (freeLiquidityAssets <= reserved) return 0;
return freeLiquidityAssets - reserved;
```
When sum exceeds free, returns 0.

### Proof of Concept (Arithmetic)

Start: free=1000, badDebt=0, protocolFee=0

After 5 settlement cycles (principal=100, fee=200, cutBps=10000, feeBps=10000):
- Each cycle: free += 300 (principal 100 + fee 200), badDebt += 200, protocolFee += 200
- Per cycle: available = free - badDebt - protocolFee
  - Cycle 1: 1200 - 200 - 200 = 800
  - Cycle 2: 1400 - 400 - 400 = 600
  - Cycle 3: 1600 - 600 - 600 = 400
  - Cycle 4: 1800 - 800 - 800 = 200
  - Cycle 5: 2000 - 1000 - 1000 = 0 (LOCKED)

### Verification Status: TRUE POSITIVE
**Severity: MEDIUM**
- Requires governance misconfiguration (cutBps + feeBps > 10000)
- No loss of funds (shares still represent value)
- Liveness issue: LP withdrawals and new bridge operations blocked
- Recovery requires loss event to drain badDebtReserve

### Recommendation
Add to `setPolicy`:
```solidity
require(badDebtReserveCutBps_ + protocolFeeBps_ <= BPS_DENOMINATOR, "Combined BPS exceeds 100%");
```
Or add to `_assertAccountingInvariants`:
```solidity
if (badDebtReserveAssets + protocolFeeAccruedAssets > freeLiquidityAssets) {
  revert InvariantViolation("combined_suballoc_exceeds_free");
}
```

---

## VERIFIED: LOW-01 -- Fee-on-Transfer Token Incompatibility

### Code Trace

**deposit** (line 270-277):
```solidity
shares = super.deposit(assets, receiver);    // Calls transferFrom internally
freeLiquidityAssets += assets;               // Credits the REQUESTED amount, not actual received
```

OZ ERC4626.deposit does `SafeERC20.safeTransferFrom(asset(), caller, address(this), assets)`. If the token has a transfer fee, the vault receives `assets - fee` but credits `assets` to freeLiquidityAssets.

### Verification Status: TRUE POSITIVE
**Severity: LOW**
- Standard ERC-4626 limitation (OZ does not handle this either)
- Deployed with LINK (standard ERC20, no transfer fee)
- Must be documented as an operational constraint

---

## VERIFIED: LOW-02 -- Write-Only State Variables

### Code Trace

**settledFeesEarnedAssets** (line 98): Only written at line 488. Never read by any contract function.
**realizedNavLossAssets** (line 99): Only written at lines 519 and 569. Never read by any contract function.
**targetHotReserveBps** (line 79): Only written at line 231. Never read by any guard or check.

### Verification Status: TRUE POSITIVE
**Severity: LOW/INFO**
- These are for off-chain monitoring only
- No security impact
- Gas cost: ~20K per SSTORE on each write (minor but non-zero)

---

## VERIFIED: LOW-03 -- Queue ID Reuse

### Code Trace

**dequeue** (line 63-78):
```solidity
if (currentHead >= tailRequestId) {
    headRequestId = 0;
    tailRequestId = 0;
} else {
    headRequestId = currentHead + 1;
}
```

When the last element is dequeued, both head and tail reset to 0. Next enqueue produces requestId = 0 + 1 = 1, which was the same ID as the first ever request. The old request data was deleted at line 68 (`delete _requests[currentHead]`), so no data collision.

### Verification Status: TRUE POSITIVE
**Severity: LOW/INFO**
- No on-chain security impact (old data deleted before ID reuse)
- Off-chain systems tracking request IDs must be aware of reuse

---

## FALSE POSITIVES ELIMINATED

| Finding | Reason for Elimination |
|---|---|
| F-02 (redeem double-compute) | Both `previewRedeem` calls use identical state. No divergence possible in same tx with reentrancy guard. |
| F-04 (balance check accounting) | `currentHeld = free + reserved + inFlight` correctly represents total accounting. Sub-allocations (badDebt, protocolFee) are inside `free`, not additional. |
| F-06 (uint64 overflow) | Max values are well within uint64 range. Physically impossible to overflow. |
| F-07 (CCIP revert/retry) | Standard and correct CCIP integration pattern. Vault revert = message retry. |
