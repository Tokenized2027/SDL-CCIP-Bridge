# Phase 3: State Inconsistency (Pass 2)

## 3A: Mutation Matrix

Every function that modifies each state variable:

### freeLiquidityAssets
| Function | Direction | Amount | Guard |
|---|---|---|---|
| deposit | + | assets | nonReentrant, NotGlobalPaused, DepositPaused |
| mint | + | assets (computed from shares) | nonReentrant, NotGlobalPaused, DepositPaused |
| withdraw | - | assets | nonReentrant, NotGlobalPaused, InsufficientFreeLiquidity |
| redeem | - | assets (computed from shares) | nonReentrant, NotGlobalPaused, InsufficientFreeLiquidity |
| processRedeemQueue | - | assetsDue per request | nonReentrant, OPS_ROLE |
| reserveLiquidity | - | amount | nonReentrant, OPS_ROLE, InsufficientFreeLiquidity, UtilCap |
| releaseReservation | + | route.amount | nonReentrant, OPS_ROLE |
| expireReservation | + | route.amount | nonReentrant, permissionless |
| reconcileSettlementSuccess | + | principalAssets + netFeeIncomeAssets | nonReentrant, SETTLEMENT_ROLE |
| reconcileSettlementLoss | + | recoveredAssets | nonReentrant, SETTLEMENT_ROLE |
| emergencyReleaseFill | + | recoveredAssets | nonReentrant, GOVERNANCE_ROLE |
| claimProtocolFees | - | amount | nonReentrant, GOVERNANCE_ROLE |

### reservedLiquidityAssets
| Function | Direction | Amount |
|---|---|---|
| reserveLiquidity | + | amount |
| releaseReservation | - | route.amount |
| expireReservation | - | route.amount |
| executeFill | - | amount |

### inFlightLiquidityAssets
| Function | Direction | Amount |
|---|---|---|
| executeFill | + | amount |
| reconcileSettlementSuccess | - | principalAssets |
| reconcileSettlementLoss | - | principalAssets |
| emergencyReleaseFill | - | fill.amount |

### badDebtReserveAssets
| Function | Direction | Amount |
|---|---|---|
| reconcileSettlementSuccess | + | reserveCut = netFeeIncome * cutBps / 10000 |
| reconcileSettlementLoss | - | min(badDebtReserve, loss) |
| emergencyReleaseFill | - | min(badDebtReserve, loss) |

### protocolFeeAccruedAssets
| Function | Direction | Amount |
|---|---|---|
| reconcileSettlementSuccess | + | netFeeIncome * feeBps / 10000 |
| claimProtocolFees | - | amount |

### settledFeesEarnedAssets (write-only tracking)
| Function | Direction | Amount |
|---|---|---|
| reconcileSettlementSuccess | + | distributable |

### realizedNavLossAssets (write-only tracking)
| Function | Direction | Amount |
|---|---|---|
| reconcileSettlementLoss | + | uncovered loss |
| emergencyReleaseFill | + | uncovered loss |

## 3B: Parallel Path Comparison

### Settlement Success vs Settlement Loss
| Aspect | reconcileSettlementSuccess | reconcileSettlementLoss |
|---|---|---|
| inFlight decrement | -= principalAssets | -= principalAssets |
| free increment | += principalAssets + netFeeIncomeAssets | += recoveredAssets |
| badDebt change | += reserveCut | -= reserveAbsorb |
| protocolFee change | += protocolFee | (unchanged) |
| Balance check | YES (line 474-477) | NO |
| Terminal state | SettledSuccess | SettledLoss |

**FINDING [S-01] (LOW)**: The loss path has NO balance check for `recoveredAssets`. The assumption is that recovered tokens are already in the vault (in-flight tokens never physically leave). If the architecture evolves to actually send tokens cross-chain, the loss path would need a balance check similar to the success path. **Currently safe due to architectural assumption.**

### releaseReservation vs expireReservation
| Aspect | releaseReservation | expireReservation |
|---|---|---|
| Auth | OPS_ROLE | Permissionless |
| Pause check | globalPaused + reservePaused | None |
| Timestamp check | None | block.timestamp >= expiry |
| State mutation | Identical | Identical |

**SOUND**: Both produce the same state transition (Reserved -> Released, reserved -> free). The permissionless path requires timestamp >= expiry, preventing premature release.

### reconcileSettlementLoss vs emergencyReleaseFill
| Aspect | reconcileSettlementLoss | emergencyReleaseFill |
|---|---|---|
| Auth | SETTLEMENT_ROLE | GOVERNANCE_ROLE |
| Pause check | globalPaused | None |
| Timelock | None | fill.executedAt + emergencyReleaseDelay |
| Fill status check | Executed | Executed |
| State mutation | Identical | Identical |

**SOUND**: Both produce the same accounting (inFlight -> free/loss). emergencyReleaseFill is the escape hatch when CCIP settlement fails.

## 3C: Operation Ordering Within Functions

### reconcileSettlementSuccess (lines 457-495)
1. Validate fill status and amount match (lines 463-469) -- READ phase
2. Validate route status and fill link (lines 468-469) -- READ phase
3. Balance check (lines 474-477) -- READ phase (external view call)
4. Compute fee splits (lines 479-482) -- COMPUTE phase (pure arithmetic)
5. Update accounting buckets (lines 484-488) -- WRITE phase
6. Update state machine (lines 490-491) -- WRITE phase
7. Invariant check (line 493) -- VERIFY phase
8. Emit event (line 494) -- EMIT phase

**Ordering analysis**: READ -> COMPUTE -> WRITE -> VERIFY -> EMIT. This is the correct pattern. All reads happen before any writes. The invariant check at step 7 uses the FINAL state (after all writes), which is correct.

**Potential issue**: Between steps 3 and 5, no state changes occur in THIS contract. However, the balance check at step 3 reads `IERC20(asset()).balanceOf(address(this))` which is an external view call. If the asset token is malicious and returns a different value on repeated calls, this could be exploited. **Mitigation**: The contract uses SafeERC20 and the balance check is a one-shot read. The OZ ERC20 implementation is deterministic. **SOUND for standard ERC20 assets.**

### processRedeemQueue (lines 336-363)
1. Validate maxRequests > 0 (line 343)
2. Loop: peek -> previewRedeem -> check liquidity -> dequeue -> burn -> transfer -> decrement free (lines 345-359)
3. Invariant check (line 362)

**FINDING [S-02] (MEDIUM): Exchange rate drift across loop iterations.**
Within each loop iteration:
- Line 349: `assetsDue = previewRedeem(request.shares)` -- uses CURRENT totalAssets and totalSupply
- Line 354: `_burn(address(this), dequeued.shares)` -- DECREASES totalSupply
- Line 355: `freeLiquidityAssets -= assetsDue` -- DECREASES totalAssets (via freeLiquidity)
- Line 356: `safeTransfer(dequeued.receiver, assetsDue)` -- external call

After the burn and free decrement, the NEXT iteration's `previewRedeem` sees a different exchange rate. The first-burned shares get the pre-burn rate, and subsequent shares get a post-burn rate.

**Direction of drift**: After burning N shares and removing X assets, if X/N = the current exchange rate, then:
- New totalAssets = oldTotalAssets - X
- New totalSupply = oldTotalSupply - N
- New rate = (oldTotalAssets - X) / (oldTotalSupply - N)

If the rate was fair (X = rate * N), then the new rate should be the same. Actually:
- oldRate = oldTotalAssets / oldTotalSupply
- newRate = (oldTotalAssets - oldRate*N) / (oldTotalSupply - N) = oldRate * (oldTotalSupply - N) / (oldTotalSupply - N) = oldRate

So the rate should NOT change across iterations IF rounding is exact. With integer division rounding, there can be up to 1 wei per iteration drift. Over 1000 iterations, this is 1000 wei -- negligible.

**Wait -- but `previewRedeem` uses the OZ virtual offset formula, which is `(shares * (totalAssets + 1)) / (totalSupply + 10^offset)`. The +1 and +10^offset create a rounding bias that compounds.** Let me trace more carefully:

With offset=3:
previewRedeem(shares) = shares * (totalAssets + 1) / (totalSupply + 1000)

After burning shares and removing assets proportionally:
newRate = (totalAssets - removedAssets + 1) / (totalSupply - burnedShares + 1000)

The +1 in numerator and +1000 in denominator create a slight downward bias (returns fewer assets than exact). This bias is CONSISTENT across iterations. The drift is at most 1 wei per call due to integer truncation, not per-share.

**Verdict: LOW** -- the drift is at most 1 wei per queue entry processed, which is negligible even for thousands of entries. The test confirms <0.1% drift for reasonable scenarios.

## 3D: Feynman-Enriched Targets

### From M-01: `badDebt + protocolFee > free` scenario
Let me trace this more carefully.

Starting state: fresh vault, policy: cutBps=10000, feeBps=10000 (both max).
1. Alice deposits 1000. free=1000, badDebt=0, protocolFee=0.
2. Reserve 100. free=900, reserved=100.
3. Fill 100. reserved=0, inFlight=100.
4. Settle success with principal=100, fee=200 (fee > principal).
   - inFlight -= 100. free += 100 + 200 = 300. So free = 900 + 300 = 1200.
   - reserveCut = 200 * 10000/10000 = 200. badDebt += 200. badDebt = 200.
   - protocolFee = 200 * 10000/10000 = 200. protocolFee += 200. protocolFee = 200.
   - Check: badDebt(200) <= free(1200)? YES. protocolFee(200) <= free(1200)? YES.
   - Check: badDebt + protocolFee = 400 <= free(1200)? YES (but NOT checked).
   - distributable = max(200 - 200 - 200, 0) = 0.

5. Repeat: Reserve 100, Fill 100, Settle with principal=100, fee=200.
   - free = 1200 - 100 + 100 + 200 = 1400. badDebt = 200 + 200 = 400. protocolFee = 200 + 200 = 400.
   - Check: badDebt(400) <= free(1400)? YES. protocolFee(400) <= free(1400)? YES.
   - badDebt + protocolFee = 800 <= free(1400)? YES.

6. Continue for 5 more iterations:
   - free = 1400 + 200 = 1600, 1800, 2000, 2200, 2400
   - badDebt = 600, 800, 1000, 1200, 1400
   - protocolFee = 600, 800, 1000, 1200, 1400

   At iteration 7 total:
   - free = 2400, badDebt = 1400, protocolFee = 1400
   - badDebt + protocolFee = 2800 > free(2400). **THIS IS REACHABLE!**
   - But each individual: badDebt(1400) <= free(2400)? YES. protocolFee(1400) <= free(2400)? YES.
   - `_assertAccountingInvariants` passes but `availableFreeLiquidityForLP()` sees `reserved = 1400 + 1400 = 2800 > free(2400)` and returns 0.

**WAIT -- let me recheck.** At iteration 7:
- Deposit: 1000
- After 7 settlements each adding 200 fee: free = 1000 + 7*200 = 2400 (assuming no other changes... but wait, each settlement also returns 100 principal to free).

Let me redo this precisely:

Initial: free=1000, reserved=0, inFlight=0, badDebt=0, protocolFee=0.

Round 1:
- reserveLiquidity(100): free=900, reserved=100
- executeFill(100): reserved=0, inFlight=100
- reconcileSettlementSuccess(principal=100, fee=200):
  - inFlight -= 100 -> inFlight=0
  - free += 100 + 200 = 300 -> free = 900 + 300 = 1200
  - badDebt += 200 -> badDebt=200
  - protocolFee += 200 -> protocolFee=200
  - invariant: 200 <= 1200 YES, 200 <= 1200 YES
  - fee tokens must arrive: asset.mint(vault, 200) [only the fee income, since principal was already in vault]

Round 2:
- reserveLiquidity(100): free=1100, reserved=100
  - but wait, availableForLP = 1200 - 200 - 200 = 800. 100 <= 800, OK.
- executeFill(100): reserved=0, inFlight=100
- reconcileSettlementSuccess(100, 200):
  - free = 1100 + 300 = 1400
  - badDebt = 200 + 200 = 400
  - protocolFee = 200 + 200 = 400
  - invariant: 400 <= 1400 YES, 400 <= 1400 YES

Round 3:
- available = 1400 - 400 - 400 = 600. Reserve 100, OK.
- free = 1300 + 300 = 1600, badDebt=600, protocolFee=600
- 600 <= 1600 YES, 600 <= 1600 YES

Round 4:
- available = 1600 - 600 - 600 = 400. Reserve 100, OK.
- free = 1500 + 300 = 1800, badDebt=800, protocolFee=800
- 800 <= 1800 YES, 800 <= 1800 YES

Round 5:
- available = 1800 - 800 - 800 = 200. Reserve 100, OK.
- free = 1700 + 300 = 2000, badDebt=1000, protocolFee=1000
- 1000 <= 2000 YES, 1000 <= 2000 YES
- badDebt + protocolFee = 2000 = free. available = 0!

Round 6:
- available = 2000 - 1000 - 1000 = 0. **Cannot reserve any more liquidity!**

So the system reaches a state where badDebt + protocolFee = free, and NO MORE bridge operations can occur. LPs cannot withdraw either. The vault is stuck.

**This is actually a self-correcting limit.** The vault cannot enter an insolvent state because reserveLiquidity checks availableForLP. But it CAN reach a state where all liquidity is consumed by sub-allocations, effectively halting the vault.

**Resolution**: Governance must claim protocol fees to free up liquidity. claimProtocolFees(to, amount) decreases both protocolFee and free, which reduces the sum of sub-allocations and allows availableForLP to increase once badDebt is absorbed by a loss or simply relative to the new free.

Actually wait -- claimProtocolFees decreases BOTH protocolFee AND free by the same amount. So `available = free - badDebt - protocolFee` before = `free - badDebt - protocolFee`. After claiming X: `available = (free - X) - badDebt - (protocolFee - X) = free - X - badDebt - protocolFee + X = free - badDebt - protocolFee`. Same! Claiming fees does NOT change available.

**CONFIRMED: With extreme policies, the vault can reach a permanently locked state where availableForLP = 0 and no action (including fee claims) can restore it.** The only way to unblock would be for governance to change the policy (reduce cutBps/feeBps) before the next settlement, or for a loss event to drain the badDebtReserve.

**Severity: MEDIUM** -- Only reachable with extreme policy settings (cutBps + feeBps > 10000) AND repeated fee > principal settlements. Governance-controlled. Not a loss of funds (LPs still own shares, totalAssets still reflects their value), but a liveness issue.

### State Machine Finality Verification
All terminal states are checked:
- RouteStatus: None -> Reserved -> {Released, Filled -> {SettledSuccess, SettledLoss}}
- FillStatus: None -> Executed -> {SettledSuccess, SettledLoss}

**Every state transition checks the current status.** All transitions are one-way. There is no path from a terminal state back to an active state.

Verified by:
- reserveLiquidity: requires route.status == None (line 372)
- releaseReservation: requires route.status == Reserved (line 396)
- expireReservation: requires route.status == Reserved (line 416)
- executeFill: requires route.status == Reserved (line 437), fill.status == None (line 441)
- reconcileSettlementSuccess: requires fill.status == Executed (line 466), route.status == Filled (line 469)
- reconcileSettlementLoss: same as above (lines 507, 510)
- emergencyReleaseFill: requires fill.status == Executed (line 553)

**SOUND**: No state machine transitions are reversible. No bypasses found.
