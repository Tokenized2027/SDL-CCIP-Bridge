# AI Scan Campaign Report — LaneVault4626 Suite

Date: 2026-03-12

Scope:
- `src/LaneVault4626.sol`
- `src/LaneQueueManager.sol`
- `src/LaneSettlementAdapter.sol`

Status:
- Confirmed novel findings: 1
- Open findings on current branch: 0
- Severity split: 0 Critical, 0 High, 0 Medium, 1 Low
- Existing report comparison baselines: `AUDIT-REPORT.md` and `docs/DEEP-AUDIT-REPORT.md`
- Remediation update: Fixed locally on 2026-03-12. `maxWithdraw()` and `maxRedeem()` now return `0` while `globalPaused` is active.

## Executive Summary

The LaneVault4626 suite remains the most mature target in this campaign. I did not confirm a new loss-of-funds issue after the local code review, PoC pass, and full Foundry suite run. The one fresh issue identified in the scan was an ERC-4626/integration gap:

- `maxWithdraw()` and `maxRedeem()` continued to advertise non-zero exits while `globalPaused` caused the actual exit functions to hard-revert.

This was a lower-severity surface mismatch, but it was real and new relative to the existing reports, which only fixed the deposit-side `maxDeposit()` / `maxMint()` pause behavior. It is fixed in the current branch.

## Findings

| ID | Severity | Title | Novel vs existing audit reports | Verification |
|---|---|---|---|---|
| LANE-SCAN-01 | Low | `maxWithdraw()` / `maxRedeem()` stay non-zero while global pause blocks both exit paths | Yes | PoC test + manual trace |

### LANE-SCAN-01 — `maxWithdraw()` / `maxRedeem()` stay non-zero while global pause blocks both exit paths

Locations:
- `src/LaneVault4626.sol:183`
- `src/LaneVault4626.sol:189`
- `src/LaneVault4626.sol:302`
- `src/LaneVault4626.sol:316`
- `src/LaneVault4626.sol:614`

Why it happens:
- `withdraw()` and `redeem()` both call `_requireNotGlobalPaused()`.
- `maxWithdraw()` and `maxRedeem()` do not consider `globalPaused`.
- During a global pause, integrations still see non-zero withdrawable/redeemable values even though every exit call will revert.

Impact:
- ERC-4626 routers, frontends, or monitoring jobs can advertise a live exit path that is guaranteed to fail.
- This is not a direct theft vector, but it is precisely the kind of spec-surface mismatch that causes broken automation and bad UX during incidents.

Reproduction:
- Added `test/ScanCampaignFindings.t.sol`
- The original mismatch was reproduced during the scan, and the same file now acts as a regression check for the fix.
- Verified with:
  - `forge test --match-contract ScanCampaignLaneVaultFindingsTest -vv`

Recommended fix:
- Implemented: return `0` from `maxWithdraw()` and `maxRedeem()` when `globalPaused` is true.

## Cross-Reference / Convergence

| Finding | Manual Review | PoC Test | Slither | Existing Audit Reports | Methodology Lens |
|---|---|---|---|---|---|
| `LANE-SCAN-01` | Yes | `test/ScanCampaignFindings.t.sol` | No direct detector hit | No | Pashov reviewer/judge, Trail of Bits maturity/spec sharp edge, consumer AI compliance pass |

## Novel Findings List

- `LANE-SCAN-01`: exit-cap views stay positive while `globalPaused` hard-blocks withdrawals and redeems.

Remediation status:
- Fixed on the current branch with regression coverage in `test/ScanCampaignFindings.t.sol`.

## Verification

Local verification completed:
- `forge test`
- `forge test --match-contract ScanCampaignLaneVaultFindingsTest -vv`
- `slither-scan-campaign.json`

High-signal suites that passed inside the full run:
- `LaneVault4626Test`
- `LaneVault4626AttacksTest`
- `DeepAuditLaneVaultTest`
- `SecurityAuditAttacksTest`
- `AdvancedAuditTest`
- `E2ELifecycleTest`

## Notes on Disputed Areas

I explicitly reviewed the “phantom recovered assets” angle on `reconcileSettlementLoss()` / `emergencyReleaseFill()` and did not escalate it in this report. In the current architecture, principal is treated as accounting-only during route execution, so the settlement-success balance check is about newly arrived fee income, not principal round-trips. That keeps this pass grounded and avoids inventing a bug that the code path does not actually prove.

## Methodology Sources Used

GitHub sources I could verify and use as methodology references:
- `https://github.com/pashov/skills`
- `https://github.com/trailofbits/skills`
- `https://github.com/kadenzipfel/scv-scan`
- `https://github.com/marchev/claudit`
- `https://github.com/auditmos/skills`
