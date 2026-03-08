# Phase 5: Multi-Transaction Journey Tracing

Adversarial sequences constructed for all findings to verify exploitability.

---

## Journey 1: M-01 -- Sub-allocation Lockout

### Setup
- Vault deployed with 18-decimal ERC20 token
- Governance sets policy: cutBps=10000, feeBps=10000, maxUtil=9000
- Alice deposits 1000e18

### Adversarial Sequence

```
Tx 1: alice.deposit(1000e18)
  -> free=1000e18, totalAssets=1000e18

Tx 2: ops.reserveLiquidity(route1, 100e18, expiry)
  -> available = 1000 - 0 - 0 = 1000. OK.
  -> free=900e18, reserved=100e18

Tx 3: ops.executeFill(route1, fill1, 100e18)
  -> reserved=0, inFlight=100e18

Tx 4: [mint 200e18 fee tokens to vault]
      settlement.reconcileSettlementSuccess(fill1, 100e18, 200e18)
  -> inFlight -= 100, free += 300. free=1200e18
  -> badDebt += 200e18, protocolFee += 200e18
  -> available = 1200 - 200 - 200 = 800

Tx 5-6: Repeat reserve/fill/settle with 100e18 principal, 200e18 fee
  -> free=1400, badDebt=400, protocolFee=400
  -> available = 1400 - 400 - 400 = 600

Tx 7-8: Repeat
  -> free=1600, badDebt=600, protocolFee=600
  -> available = 1600 - 600 - 600 = 400

Tx 9-10: Repeat
  -> free=1800, badDebt=800, protocolFee=800
  -> available = 1800 - 800 - 800 = 200

Tx 11-12: Repeat
  -> free=2000, badDebt=1000, protocolFee=1000
  -> available = 2000 - 1000 - 1000 = 0
  -> **LOCKED: No more reserves, no LP withdrawals**
```

### Impact Assessment
- LPs cannot withdraw (maxWithdraw returns 0)
- No new bridge operations (reserveLiquidity reverts with InsufficientFreeLiquidity)
- claimProtocolFees does not help (available stays 0)
- Only recovery: governance changes policy, then a loss event drains badDebt

### Required Conditions
1. Governance sets cutBps + feeBps > 10000 (extreme, non-standard)
2. Multiple settlements with fee > 0 (normal operation adds to sub-allocations)
3. No loss events to drain badDebtReserve
4. No governance fee claims (which don't help anyway)

### Verdict: CONFIRMED MEDIUM
Not exploitable by external attacker (requires governance misconfiguration). But a real liveness risk if governance accidentally sets extreme policy.

---

## Journey 2: Donation Attack Attempt

### Setup
- Vault with 10000e18 deposited by Alice
- Attacker has 1_000_000e18 tokens

### Adversarial Sequence

```
Tx 1: alice.deposit(10000e18)
  -> free=10000e18, shares=10000e21 (with 1e3 offset)

Tx 2: attacker.transfer(vault, 1_000_000e18)
  -> vault ERC20 balance = 1_010_000e18
  -> BUT free stays 10000e18
  -> totalAssets = free + reserved + inFlight - protocolFee = 10000e18
  -> Share price unchanged!

Tx 3: attacker.deposit(1e18)
  -> shares = 1e18 * (10000e21 + 1000) / (10000e18 + 1) ~= 1e21 (proportional)
  -> free = 10001e18
  -> Attacker gets proportional shares, no inflation
```

### Verdict: NOT EXPLOITABLE
Virtual accounting (5-bucket system) completely isolates share price from direct token donations. The vault's actual ERC20 balance can exceed accounting buckets, but the excess is "dead" -- it does not affect share price, totalAssets, or any accounting.

---

## Journey 3: Double Settlement Attempt

### Adversarial Sequence

```
Tx 1: alice.deposit(100000e18)
Tx 2: ops.reserveLiquidity(routeA, 10000e18, expiry)
Tx 3: ops.executeFill(routeA, fillA, 10000e18)
Tx 4: settlement.reconcileSettlementSuccess(fillA, 10000e18, 500e18)
  -> fillA.status = SettledSuccess, routeA.status = SettledSuccess

Tx 5: settlement.reconcileSettlementSuccess(fillA, 10000e18, 500e18)
  -> REVERT: InvalidTransition (fillA.status != Executed)

Tx 6: settlement.reconcileSettlementLoss(fillA, 10000e18, 9000e18)
  -> REVERT: InvalidTransition (fillA.status != Executed)
```

### Verdict: NOT EXPLOITABLE
One-way state machine prevents all double-settlement attempts.

---

## Journey 4: CCIP Replay Attack

### Adversarial Sequence

```
Tx 1: CCIP message arrives with messageId=X, source=(chainA, senderA)
  -> replayKey = keccak256(chainA, senderA, X) consumed
  -> Settlement processed

Tx 2: Same CCIP message replayed with same messageId=X
  -> replayKey already consumed
  -> REVERT: ReplayDetected

Tx 3: Different messageId=Y but same payload
  -> replayKey = keccak256(chainA, senderA, Y) -- different key
  -> BUT: payload.fillId is already SettledSuccess in vault
  -> vault.reconcileSettlementSuccess REVERTS: InvalidTransition
  -> Entire _ccipReceive reverts
  -> replayKey for Y is NOT consumed (transaction reverted)
```

### Verdict: NOT EXPLOITABLE
Two-layer defense: adapter replay protection + vault state machine finality.

---

## Journey 5: Queue Griefing (Gas Exhaustion)

### Adversarial Sequence

```
Tx 1: attacker.deposit(10000e18)
  -> Gets ~10000e21 shares (with offset)

Tx 2-1001: attacker.requestRedeem(1, attacker, attacker) x 1000
  -> 1000 queue entries, each with 1 share (minimum)
  -> Cost: ~30K gas per requestRedeem = 30M gas total (~1 block)

Tx 1002: ops.processRedeemQueue(1000)
  -> Processes 1000 entries
  -> Gas per entry: ~50-80K (peek + dequeue + previewRedeem + burn + transfer)
  -> Total: ~50-80M gas
  -> EXCEEDS 30M block gas limit for >500 entries!
```

### But Wait: `processRedeemQueue(maxRequests)` takes maxRequests parameter
The OPS_ROLE caller can choose `maxRequests = 100` per transaction, processing in batches. This prevents gas exhaustion.

### Impact Assessment
- No permanent DoS -- OPS can always batch
- Cost to attacker: 1000 * deposit_gas + 1000 * requestRedeem_gas ≈ 1000 * 100K = 100M gas ≈ $30 at 10 gwei/gas
- Cost to defender: 10 * processRedeemQueue(100) = 10 * ~8M gas = 80M gas ≈ $24
- Attacker cost > defender cost: NOT economically rational

### Verdict: LOW (NOT EXPLOITABLE for DoS)
Batched processing prevents gas exhaustion. Economic analysis shows attacker spends more than defender.

---

## Journey 6: Privilege Escalation via Settlement Adapter

### Adversarial Sequence

```
Tx 1: attacker calls setSettlementAdapter(attacker)
  -> REVERT: AccessControl missing GOVERNANCE_ROLE

Tx 2: attacker calls reconcileSettlementSuccess(...)
  -> REVERT: AccessControl missing SETTLEMENT_ROLE

Tx 3: compromised governance calls setSettlementAdapter(malicious)
  -> SETTLEMENT_ROLE granted to malicious contract
  -> malicious calls reconcileSettlementSuccess with fake fillId
  -> REVERT: InvalidTransition (fill must be in Executed state)

Tx 4: compromised governance + compromised OPS:
  -> OPS reserves and fills a real route
  -> malicious adapter settles with inflated fee
  -> Balance check catches: actualBalance < required
  -> REVERT: BalanceDeficit
```

### Verdict: NOT EXPLOITABLE
Even with compromised governance AND OPS roles, the balance check in reconcileSettlementSuccess prevents phantom asset inflation. The attacker would need to actually SEND tokens to the vault to match the claimed fee income.

---

## Journey 7: Fee-on-Transfer Token

### Adversarial Sequence

```
Assuming vault uses a fee-on-transfer token where 1% is burned on transfer:

Tx 1: alice.deposit(1000)
  -> super.deposit calls asset.transferFrom(alice, vault, 1000)
  -> Vault receives only 990 (10 burned)
  -> BUT: freeLiquidityAssets += 1000 (the REQUESTED amount)
  -> free(1000) > actualBalance(990)
  -> PHANTOM ASSET!

Tx 2: alice.withdraw(1000)
  -> free -= 1000, super.withdraw transfers 1000
  -> BUT vault only has 990
  -> REVERT: ERC20 insufficient balance
```

### Impact Assessment
With fee-on-transfer tokens, the vault's accounting would drift from actual balance. This is a known limitation of OZ ERC4626 which does not account for transfer fees. The vault would become progressively insolvent.

### Mitigation
The vault documentation and deployment should specify that ONLY standard ERC20 tokens (no fee-on-transfer, no rebasing) are supported. The deployed version uses LINK which is a standard ERC20.

### Verdict: LOW (KNOWN LIMITATION)
Not a code bug -- standard ERC4626 pattern. Must be documented as an operational constraint.

---

## Journey 8: Policy Change Mid-Flight Exploitation

### Adversarial Sequence

```
Tx 1: deposit 1M, policy: cutBps=1000, feeBps=500
Tx 2: ops.reserveLiquidity(100K), ops.executeFill(100K)
  -> inFlight=100K

Tx 3: governance.setPolicy(cutBps=0, feeBps=0)
  -> Policy immediately active

Tx 4: settlement.reconcileSettlementSuccess(100K, 10K fee)
  -> Uses NEW policy: reserveCut=0, protocolFee=0, distributable=10K
  -> ALL fee income goes to LP NAV
  -> No bad debt reserve built up
```

### Impact Assessment
Governance can retroactively change fee splits for in-flight fills. This is a governance power, not a vulnerability. Governance is trusted. The mid-flight policy change could benefit or harm LPs depending on direction.

### Verdict: LOW (GOVERNANCE TRUST ASSUMPTION)
Documented in test ADV-13. Not exploitable by external attackers.
