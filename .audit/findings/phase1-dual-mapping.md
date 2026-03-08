# Phase 1: Dual Mapping

## 1A: Function-State Matrix

### LaneVault4626.sol -- Every Entry Point

| Function | Access | State Reads | State Writes | Guards | External Calls |
|---|---|---|---|---|---|
| `deposit(assets,receiver)` | public | globalPaused, depositPaused | freeLiquidityAssets += assets | nonReentrant, NotGlobalPaused, DepositPaused | super.deposit (ERC4626 transferFrom + mint) |
| `mint(shares,receiver)` | public | globalPaused, depositPaused | freeLiquidityAssets += assets | nonReentrant, NotGlobalPaused, DepositPaused | super.mint (ERC4626 transferFrom + mint) |
| `withdraw(assets,receiver,owner)` | public | globalPaused, freeLiquidityAssets, protocolFeeAccruedAssets, badDebtReserveAssets | freeLiquidityAssets -= assets | nonReentrant, NotGlobalPaused, InsufficientFreeLiquidity | super.withdraw (ERC4626 burn + transfer) |
| `redeem(shares,receiver,owner)` | public | globalPaused, freeLiquidityAssets, protocolFeeAccruedAssets, badDebtReserveAssets, totalAssets, totalSupply | freeLiquidityAssets -= assets | nonReentrant, NotGlobalPaused, InsufficientFreeLiquidity | super.redeem (ERC4626 burn + transfer) |
| `requestRedeem(shares,receiver,owner)` | external | globalPaused, balanceOf(owner) | shares transferred owner->vault, queue.enqueue | nonReentrant, NotGlobalPaused | _transfer, _spendAllowance, queueManager.enqueue |
| `processRedeemQueue(maxRequests)` | external | globalPaused, queueManager.peek/dequeue, previewRedeem, availableFreeLiquidity | freeLiquidityAssets -= assetsDue, shares burned | nonReentrant, OPS_ROLE, NotGlobalPaused | queueManager.peek/dequeue, _burn, safeTransfer |
| `reserveLiquidity(routeId,amount,expiry)` | external | globalPaused, reservePaused, routes[routeId].status, freeLiquidityAssets, reservedLiquidityAssets, inFlightLiquidityAssets, totalAssets, maxUtilizationBps | freeLiquidityAssets -= amount, reservedLiquidityAssets += amount, routes[routeId] = Reserved | nonReentrant, OPS_ROLE, NotGlobalPaused, ReservePaused | none |
| `releaseReservation(routeId)` | external | globalPaused, reservePaused, routes[routeId] | reservedLiquidityAssets -= amount, freeLiquidityAssets += amount, route.status = Released | nonReentrant, OPS_ROLE, NotGlobalPaused, ReservePaused | none |
| `expireReservation(routeId)` | external | routes[routeId], block.timestamp | reservedLiquidityAssets -= amount, freeLiquidityAssets += amount, route.status = Released | nonReentrant, permissionless | none |
| `executeFill(routeId,fillId,amount)` | external | globalPaused, reservePaused, routes[routeId], fills[fillId] | reservedLiquidityAssets -= amount, inFlightLiquidityAssets += amount, route.status = Filled, fill = Executed | nonReentrant, OPS_ROLE, NotGlobalPaused, ReservePaused | none |
| `reconcileSettlementSuccess(fillId,principal,fee)` | external | globalPaused, fills[fillId], routes[routeId], asset.balanceOf(vault), freeLiquidityAssets, reservedLiquidityAssets, inFlightLiquidityAssets, badDebtReserveCutBps, protocolFeeBps | inFlightLiquidityAssets -= principal, freeLiquidityAssets += principal+fee, badDebtReserveAssets += reserveCut, protocolFeeAccruedAssets += protocolFee, settledFeesEarnedAssets += distributable, fill/route = SettledSuccess | nonReentrant, SETTLEMENT_ROLE, NotGlobalPaused | asset.balanceOf (view) |
| `reconcileSettlementLoss(fillId,principal,recovered)` | external | globalPaused, fills[fillId], routes[routeId], badDebtReserveAssets | inFlightLiquidityAssets -= principal, freeLiquidityAssets += recovered, badDebtReserveAssets -= reserveAbsorb, realizedNavLossAssets += uncovered, fill/route = SettledLoss | nonReentrant, SETTLEMENT_ROLE, NotGlobalPaused | none |
| `emergencyReleaseFill(fillId,recovered)` | external | fills[fillId], routes[routeId], block.timestamp, emergencyReleaseDelay, badDebtReserveAssets | inFlightLiquidityAssets -= principal, freeLiquidityAssets += recovered, badDebtReserveAssets -= reserveAbsorb, realizedNavLossAssets += uncovered, fill/route = SettledLoss | nonReentrant, GOVERNANCE_ROLE | none |
| `claimProtocolFees(to,amount)` | external | globalPaused, protocolFeeAccruedAssets, freeLiquidityAssets | protocolFeeAccruedAssets -= amount, freeLiquidityAssets -= amount | nonReentrant, GOVERNANCE_ROLE, NotGlobalPaused | safeTransfer |
| `setPolicy(...)` | external | none | badDebtReserveCutBps, maxUtilizationBps, targetHotReserveBps, protocolFeeBps, protocolFeeCapBps | GOVERNANCE_ROLE | none |
| `setPauseFlags(...)` | external | none | globalPaused, depositPaused, reservePaused | PAUSER_ROLE | none |
| `setSettlementAdapter(addr)` | external | settlementAdapter | settlementAdapter, SETTLEMENT_ROLE grant/revoke | GOVERNANCE_ROLE | _grantRole, _revokeRole |
| `setTransferAllowlistEnabled(bool)` | external | none | transferAllowlistEnabled | GOVERNANCE_ROLE | none |
| `setTransferAllowlisted(addr,bool)` | external | none | isTransferAllowlisted[addr] | GOVERNANCE_ROLE | none |
| `setEmergencyReleaseDelay(uint48)` | external | none | emergencyReleaseDelay | GOVERNANCE_ROLE | require >= 1 day |
| `totalAssets()` | view | freeLiquidityAssets, reservedLiquidityAssets, inFlightLiquidityAssets, protocolFeeAccruedAssets | none | none | none |
| `maxDeposit(addr)` | view | globalPaused, depositPaused | none | none | none |
| `maxMint(addr)` | view | globalPaused, depositPaused | none | none | none |
| `maxWithdraw(owner)` | view | balanceOf(owner), totalAssets, totalSupply, freeLiquidityAssets, protocolFeeAccruedAssets, badDebtReserveAssets | none | none | none |
| `maxRedeem(owner)` | view | same as maxWithdraw | none | none | none |
| `availableFreeLiquidityForLP()` | view | freeLiquidityAssets, protocolFeeAccruedAssets, badDebtReserveAssets | none | none | none |

### LaneSettlementAdapter.sol

| Function | Access | State Reads | State Writes | Guards | External Calls |
|---|---|---|---|---|---|
| `setAllowedSource(chain,sender,bool)` | external | vault.GOVERNANCE_ROLE, vault.hasRole | isAllowedSource[chain][sender] | _requireVaultGovernance | vault.GOVERNANCE_ROLE(), vault.hasRole() |
| `_ccipReceive(message)` | internal (via ccipReceive) | isAllowedSource, replayConsumed | replayConsumed[key] = true | Source allowlist, replay check, payload version/vault/chainId validation | vault.reconcileSettlementSuccess or vault.reconcileSettlementLoss |
| `computeReplayKey(...)` | view | none | none | none | none |
| `getFee(...)` | view | none | none | none | IRouterClient.getFee |

### LaneQueueManager.sol

| Function | Access | State Reads | State Writes | Guards | External Calls |
|---|---|---|---|---|---|
| `enqueue(owner,receiver,shares)` | external | tailRequestId, headRequestId | tailRequestId, headRequestId (if first), _requests[id] | onlyVault | none |
| `dequeue()` | external | headRequestId, tailRequestId, _requests[head] | delete _requests[head], headRequestId (advance or reset), tailRequestId (reset if empty) | onlyVault | none |
| `peek()` | view | headRequestId, tailRequestId, _requests[head] | none | none | none |
| `pendingCount()` | view | headRequestId, tailRequestId | none | none | none |
| `getRequest(id)` | view | _requests[id] | none | none | none |

## 1B: Coupled State Dependency Map

**When X changes, what MUST also change?**

| State Variable Changed | Must Also Change | Sync Enforced? |
|---|---|---|
| freeLiquidityAssets increases (deposit) | asset must have been transferred in via super.deposit | YES (OZ ERC4626 does transferFrom before _mint) |
| freeLiquidityAssets decreases (withdraw/redeem) | asset must be transferred out via super.withdraw/redeem | YES (OZ ERC4626 does transfer after _burn) |
| freeLiquidityAssets decreases (reserveLiquidity) | reservedLiquidityAssets must increase by same | YES (line 380-381) |
| freeLiquidityAssets increases (releaseReservation/expireReservation) | reservedLiquidityAssets must decrease by same | YES (line 399-400 / 420-421) |
| reservedLiquidityAssets decreases (executeFill) | inFlightLiquidityAssets must increase by same | YES (line 443-444) |
| inFlightLiquidityAssets decreases (reconcileSettlementSuccess) | freeLiquidityAssets must increase by principal + fee | YES (line 484-485) |
| inFlightLiquidityAssets decreases (reconcileSettlementLoss) | freeLiquidityAssets must increase by recovered | YES (line 516-517) |
| badDebtReserveAssets increases | freeLiquidityAssets must have increased first (via fee income settlement) | YES -- fee income added to free before reserve allocated |
| protocolFeeAccruedAssets increases | freeLiquidityAssets must have increased first (via fee income settlement) | YES -- same |
| protocolFeeAccruedAssets decreases (claim) | freeLiquidityAssets must decrease by same, asset must transfer out | YES (line 533-535) |
| badDebtReserveAssets decreases (loss absorption) | realizedNavLossAssets increases by uncovered | YES (line 518-519 / 568-569) |
| shares escrowed (requestRedeem) | balanceOf(owner) decreases, balanceOf(vault) increases, queue.enqueue | YES (line 330-332) |
| shares burned (processRedeemQueue) | balanceOf(vault) decreases, totalSupply decreases, freeLiquidityAssets decreases, asset transferred to receiver | YES (line 354-356) |

## 1C: Cross-Reference -- Gaps Found

### GAP-1: `reconcileSettlementSuccess` balance check does NOT account for `badDebtReserveAssets` or `protocolFeeAccruedAssets`
**Line 474-477**: The balance check verifies `actualBalance >= currentHeld + netFeeIncomeAssets` where `currentHeld = free + reserved + inFlight`. This is correct because badDebtReserveAssets and protocolFeeAccruedAssets are SUB-allocations of freeLiquidityAssets (not additional tokens). The real tokens backing them are already counted in `freeLiquidityAssets`.
**Verdict: SOUND** -- not a gap.

### GAP-2: `reconcileSettlementLoss` has NO balance check
**Lines 497-526**: Unlike `reconcileSettlementSuccess`, the loss path does NOT verify `asset.balanceOf(vault) >= expected`. If `recoveredAssets > 0`, those tokens must have arrived but there is no verification. However, the loss path only REDUCES inFlight and adds `recoveredAssets` to free. Since `recoveredAssets <= principalAssets` and `inFlightLiquidityAssets -= principalAssets`, the accounting only shrinks. The vault does not NEED new tokens for the loss path -- the recovered amount represents tokens that were already in the vault (in-flight tokens never actually leave for this accounting model).
**Verdict: SOUND for the current architecture** -- in-flight tokens never physically leave the vault (the actual cross-chain send happens outside this contract). If architecture changes to actually send tokens cross-chain, this becomes a vulnerability.

### GAP-3: `processRedeemQueue` exchange rate drift between peek and dequeue
**Lines 346-360**: `previewRedeem` is called at line 349, then `dequeue` at 352, then `_burn` at 354. The `previewRedeem` call and the `_burn` happen in the same transaction, and between iterations of the loop, the exchange rate changes because burning shares changes `totalSupply` while `totalAssets` also changes (freeLiquidityAssets decreases). Each subsequent iteration sees a slightly different exchange rate.
**Verdict: SUSPECT** -- rate drift between iterations is a known design choice. The test `test_exchangeRateDrift_batchProcessing` shows <0.1% drift. However, for very large share burns, this could become material. Technically earlier queue participants get slightly less per share since later participants benefit from the burn. This is the CORRECT behavior per the code (first-out gets the pre-burn rate), but worth documenting as a design consideration.

### GAP-4: `emergencyReleaseFill` does not check globalPaused
**Lines 545-576**: Unlike all other state-changing functions, `emergencyReleaseFill` does NOT call `_requireNotGlobalPaused()`. This is intentional -- emergency releases should work even when the vault is globally paused (this is a safety valve). **Verdict: SOUND -- intentional design.**

### GAP-5: `expireReservation` does not check globalPaused or reservePaused
**Lines 412-429**: Permissionless reservation expiry does not check pause flags. This is correct -- expired reservations should be clearable regardless of pause state to prevent permanent liquidity locking.
**Verdict: SOUND -- intentional design.**

### GAP-6: `settledFeesEarnedAssets` is write-only (never read in contract logic)
**Line 98, 488**: `settledFeesEarnedAssets` is incremented in `reconcileSettlementSuccess` but never read by any contract logic. It is only used for external tracking.
**Verdict: LOW -- informational only. No security impact.**

### GAP-7: `realizedNavLossAssets` is write-only (never read in contract logic)
**Line 99, 519, 569**: Same as GAP-6. Only for external tracking.
**Verdict: LOW -- informational only.**

### GAP-8: `targetHotReserveBps` is stored but never enforced
**Line 79**: This policy parameter is set via `setPolicy` but never used in any guard or check within the contract.
**Verdict: LOW -- informational. Potential future use, but currently dead code.**

### GAP-9: Queue ID reset behavior on empty queue
**LaneQueueManager.sol lines 70-75**: When the last item is dequeued, both `headRequestId` and `tailRequestId` reset to 0. The next enqueue starts at ID 1 again. This means IDs are reused across cycles. While the old request data is deleted (line 68), this could cause confusion for off-chain systems tracking request IDs.
**Verdict: LOW -- informational. No on-chain security impact since requests are deleted before ID reuse.**
