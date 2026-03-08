# Phase 4: Feedback Loop

## Iteration 1: State findings -> Feynman re-interrogation

### From M-01/3D: Sub-allocation overflow -> What masks this?

**Question (Feynman Cat 1)**: WHY does `_assertAccountingInvariants` only check individual bounds, not the sum?

**Analysis**: Looking at line 604-611, the invariant was designed to prevent individual sub-allocations from exceeding free liquidity (which would cause underflow in other operations). The sum check was likely omitted because in normal operation (cutBps + feeBps <= 10000), the sub-allocations come from fee income which is always added to free alongside the principal. The sum of sub-allocations from a single settlement equals `reserveCut + protocolFee <= feeIncome`, and `feeIncome` was added to `free`. So incrementally, the sum cannot exceed free on any single operation.

However, the bug is CUMULATIVE. Each settlement adds to badDebt and protocolFee without any corresponding drain. badDebtReserve only drains on loss events, and protocolFee only drains on governance claims. If neither occurs over many settlements, the sums accumulate.

**Key insight**: The cumulative overflow is only possible when `cutBps + feeBps > 10000` (meaning per-settlement sub-allocation exceeds 100% of fee income). With `cutBps = 10000 AND feeBps = 10000`, each settlement allocates `2 * fee` to sub-allocations but only `fee` new tokens were added. The excess `fee` is implicitly taken from the principal return to `free`.

**Resolution path**: Add `if (badDebtReserveAssets + protocolFeeAccruedAssets > freeLiquidityAssets) revert ...` to `_assertAccountingInvariants`. OR add a governance constraint that `cutBps + feeBps <= 10000` in `setPolicy`.

### From S-02: Queue drift -> Can this be weaponized?

**Question (Feynman Cat 7)**: Can an attacker create a sequence that amplifies the 1-wei-per-iteration drift?

**Analysis**: The drift per iteration is at most 1 wei due to integer truncation in `previewRedeem`. To accumulate meaningful drift, an attacker would need millions of queue entries. Each entry requires:
1. Depositing assets (getting shares)
2. Calling requestRedeem (escrowing shares)

The cost of creating queue entries is proportional to the gas cost per entry (~30K gas for requestRedeem) plus the deposit gas. To create 1M entries would cost ~30B gas = ~500 block's worth at 30M gas limit. This is impractical.

Even with 1M entries, the total drift would be ~1M wei = 1e-12 of a token with 18 decimals. Negligible.

**Verdict: NOT WEAPONIZABLE.** S-02 downgraded to LOW/INFO.

## Iteration 2: Feynman findings -> State dependency expansion

### From F-05: distributable = 0 when cutBps + feeBps > 10000

**Question (Feynman Cat 3)**: Is there an inconsistency between how `distributable` is tracked vs how it affects LP NAV?

**Analysis**: `settledFeesEarnedAssets` accumulates `distributable` (line 488), which is the portion of fee income that flows to LP NAV. When distributable is 0, NO fee income flows to LPs. But the fee income tokens ARE added to `freeLiquidityAssets` (line 485). And `totalAssets()` includes `freeLiquidityAssets` but subtracts only `protocolFeeAccruedAssets` (line 162-167).

So with extreme policy: `totalAssets = free + reserved + inFlight - protocolFee`. The `badDebtReserve` is NOT subtracted. This means LPs see the badDebtReserve as part of their NAV. The fee income that goes to badDebtReserve IS reflected in LP NAV (because badDebtReserve is a sub-allocation of free, and totalAssets includes free minus only protocolFee).

**But wait**: `availableFreeLiquidityForLP = free - protocolFee - badDebt`. LPs can only withdraw up to this amount. So while they SEE the badDebtReserve in their NAV (totalAssets), they CANNOT withdraw it. This is intentional -- badDebtReserve is insurance that benefits LPs by absorbing losses.

**Verdict: SOUND**. The accounting is consistent. LPs benefit from badDebtReserve via loss absorption, not direct withdrawal.

## Iteration 3: New State analysis from cumulative overflow

### Can fee claims recover from the locked state?

As analyzed in 3D, `claimProtocolFees(to, amount)` decreases both `protocolFeeAccruedAssets` and `freeLiquidityAssets` by the same amount. So:
- Before: available = free - badDebt - protocolFee
- After claiming X: available = (free - X) - badDebt - (protocolFee - X) = free - badDebt - protocolFee
- Same!

So fee claims DO NOT restore available liquidity. This confirms the finding.

### Can policy changes help?

If governance changes `cutBps` and `feeBps` to lower values, the NEXT settlement would add less to sub-allocations. But existing accumulated badDebt and protocolFee remain. Only loss events (draining badDebt) or the passage of time with no new fee income can help.

Actually, if governance sets protocolFeeBps = 0 and badDebtReserveCutBps = 0, future settlements add 0 to both sub-allocations. But existing balances remain. The only drain mechanisms:
- protocolFee: claimProtocolFees (which does NOT help as shown above)
- badDebt: loss absorption (reconcileSettlementLoss, emergencyReleaseFill)

So the ONLY way to recover from the locked state is:
1. Take a loss that drains badDebtReserve
2. Then badDebt decreases, and available = free - badDebt - protocolFee increases
3. This allows new operations

**This is a governance footgun, not an attack vector.** Severity remains MEDIUM.

## Iteration 4: Cross-contract state analysis

### LaneSettlementAdapter -> LaneVault4626 coupling

The adapter calls `vault.reconcileSettlementSuccess` or `vault.reconcileSettlementLoss`. These are the ONLY functions that modify settlement state. The adapter has no direct access to accounting buckets.

**Question**: Can a malicious adapter (if SETTLEMENT_ROLE is compromised) inflate accounting?

The adapter is set via `setSettlementAdapter` (GOVERNANCE_ROLE). If governance sets a malicious adapter, it could:
1. Call `reconcileSettlementSuccess(fillId, principal, HUGE_FEE)` -- but the balance check at line 474-477 would catch this (actual balance would not cover the claimed fee).
2. Call `reconcileSettlementLoss(fillId, principal, 0)` -- this would zero out the fill, putting the loss on LPs. This is a governance attack, not a code vulnerability.

**Verdict: SOUND** -- SETTLEMENT_ROLE is equivalent to governance trust.

## Convergence

No new findings emerged in iterations 3-4. Feedback loop converges.

### Final Finding List from Feedback Loop:
| ID | Severity | Description | Confirmed |
|---|---|---|---|
| M-01 | MEDIUM | Cumulative sub-allocation overflow blocks LP operations with extreme policy | YES |
| S-01 | LOW | Loss path has no balance check (safe in current architecture) | YES |
| S-02 | LOW | Queue processing exchange rate drift (1 wei per iteration, not weaponizable) | YES, downgraded to LOW |
| GAP-6/7/8 | LOW | Write-only state variables, dead code | YES, informational |
| GAP-9 | LOW | Queue ID reuse | YES, informational |
