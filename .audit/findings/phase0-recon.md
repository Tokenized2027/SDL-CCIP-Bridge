# Phase 0: Attacker Recon

## Q0.1: ATTACK GOALS -- What's the WORST an attacker can achieve?

1. **Drain vault assets**: Manipulate share price, settlement accounting, or queue processing to extract more tokens than entitled.
2. **Phantom asset inflation**: Credit `freeLiquidityAssets` without corresponding real token balance, creating insolvency.
3. **Double settlement**: Settle the same fill/route twice to double-credit principal + fees.
4. **Cross-chain replay**: Replay a CCIP settlement message to credit fees/principal multiple times.
5. **Grief/DoS**: Spam the redemption queue to make `processRedeemQueue` exceed block gas limit, permanently locking LP funds.
6. **Privilege escalation**: Gain OPS_ROLE/SETTLEMENT_ROLE/GOVERNANCE_ROLE to manipulate state machines or claim protocol fees.
7. **Share price manipulation**: Inflate/deflate share price to steal from other depositors (classic ERC-4626 inflation attack).
8. **Reservation locking**: Lock liquidity in eternal reservations with no expiry enforcement.

## Q0.2: NOVEL CODE -- What's NOT a fork of battle-tested code?

All four `src/` contracts are **custom, novel code** (NOT forked from OZ vaults or existing CCIP bridges):

- `LaneVault4626.sol` (616 LOC): Custom 5-bucket accounting layered on top of OZ ERC4626. The bucket system (free/reserved/inFlight/badDebtReserve/protocolFee), dual state machines (Route + Fill), and redemption queue integration are all novel.
- `LaneQueueManager.sol` (91 LOC): Custom FIFO queue. Simple but novel implementation with head/tail index tracking and reset-on-empty behavior.
- `LaneSettlementAdapter.sol` (104 LOC): Custom CCIP receiver with replay protection and domain binding. Builds on Chainlink CCIPReceiver but all validation logic is novel.
- `LaneVaultScaffold.sol` (227 LOC): Simulation scaffold, NOT deployed. Lower risk.

**Battle-tested dependencies**: OpenZeppelin 5.0.2 (ERC20, ERC4626, AccessControlDefaultAdminRules, ReentrancyGuard, SafeERC20), Chainlink CCIP 1.6.1 (CCIPReceiver).

## Q0.3: VALUE STORES -- Where does value actually sit?

| Value Store | Location | Description |
|---|---|---|
| `freeLiquidityAssets` | LaneVault4626 state | Available liquid tokens -- the primary withdrawal source for LPs |
| `reservedLiquidityAssets` | LaneVault4626 state | Tokens earmarked for bridge fills but not yet sent |
| `inFlightLiquidityAssets` | LaneVault4626 state | Tokens conceptually in transit cross-chain (still in vault ERC20 balance but committed) |
| `badDebtReserveAssets` | LaneVault4626 state | Insurance reserve -- sub-allocation of freeLiquidity |
| `protocolFeeAccruedAssets` | LaneVault4626 state | Accrued protocol fees -- sub-allocation of freeLiquidity |
| `asset().balanceOf(vault)` | ERC20 balance | Actual token balance; must always >= free + reserved + inFlight |
| Share balances (`balanceOf`) | ERC20 state | LP ownership claims on the vault totalAssets |
| Queue entries (`_requests`) | LaneQueueManager | Escrowed share redemption requests awaiting processing |

## Q0.4: COMPLEX PATHS -- What's the most complex interaction path?

**Full Bridge Lifecycle + Queue + Settlement + Fee Split:**
1. Multiple LPs deposit (shares minted, freeLiquidity increased)
2. OPS reserves liquidity for a route (free -> reserved)
3. OPS executes fill (reserved -> inFlight)
4. Cross-chain settlement arrives via CCIP to adapter
5. Adapter validates (source allowlist, replay, domain binding, version)
6. Adapter calls vault reconcileSettlementSuccess or reconcileSettlementLoss
7. Vault applies fee split (badDebtReserveCut + protocolFee + distributable)
8. Vault updates all 5 buckets atomically
9. Meanwhile, LPs have queued redemptions (shares escrowed in vault)
10. OPS processes queue: converts shares at current exchange rate, burns shares, transfers assets
11. Governance claims protocol fees

**Critical complexity points:**
- Steps 6-8: Settlement accounting must perfectly match real token movements
- Step 10: Exchange rate changes between enqueue and dequeue (shares depreciate on loss)
- Policy changes mid-flight: governance can change fee split parameters while fills are in-flight

## Q0.5: COUPLED VALUE -- Which value stores have DEPENDENT accounting?

| Coupling | Description | Risk |
|---|---|---|
| `free + reserved + inFlight = gross` | Sum of three buckets defines total vault value. Any mutation must maintain this. | Drift = insolvency |
| `totalAssets() = gross - protocolFee` | LP NAV excludes protocol fees. Fee accrual directly impacts share price. | Miscalculation = share price manipulation |
| `badDebtReserve <= free` AND `protocolFee <= free` | Both are sub-allocations of free liquidity. Must never exceed free. | Violation = underflow revert, stuck vault |
| `availableForLP = free - protocolFee - badDebt` | Triple coupling. LP withdrawals bounded by this. | Incorrect = over-withdrawal or locked funds |
| `shares(escrowed in vault) + shares(held by users) = totalSupply` | Queue escrow must conserve total shares. | Violation = phantom shares |
| `asset.balanceOf(vault) >= free + reserved + inFlight` | Real balance must always cover virtual accounting. | Deficit = insolvency |
| Route.amount == Fill.amount == settlement principal | State machine links these values. Settlement MUST match. | Mismatch = accounting drift |
