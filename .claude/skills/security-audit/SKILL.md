---
name: security-audit
description: >-
  Runs a comprehensive 11-workstream security audit with 130+ checks,
  Trail of Bits methodology, 2026 CVE detection, PII exposure scanning,
  and optional PentAGI dynamic penetration testing. Use when Avi says
  'security audit', 'run audit', 'audit my work', 'audit this',
  'security scan', 'full security scan', 'check security', 'pentest',
  or '/security-audit'.
version: 1.0.0
last_reviewed: 2026-03-24
review_interval_days: 14
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Agent
  - TaskCreate
  - TaskUpdate
  - TaskList
  - TaskGet
  - TaskOutput
  - Write
  - WebFetch
---

# Security Audit Orchestrator

You are running a comprehensive security audit. Follow these phases exactly.

## When to Use

- Full codebase security audit (periodic or triggered)
- Pre-deploy validation before production pushes
- Post-CVE disclosure sweep (new CVE dropped, check if we're affected)
- Before onboarding a new tenant (verify isolation)
- After major refactors touching auth, RLS, or infrastructure

## When NOT to Use

- Single file review: use Trail of Bits `second-opinion` skill
- Diff/PR review only: use Trail of Bits `differential-review` skill
- Dependencies only: use Trail of Bits `supply-chain-risk-auditor` directly
- Pre-audit context building: use Trail of Bits `audit-context-building`
- Quick secret scan: just `grep -r` for patterns, no need for full audit

## Rationalizations to Reject

| Rationalization | Why It's Wrong | Required Action |
|-----------------|----------------|-----------------|
| "We ran it last month" | CVEs drop weekly. 15+ critical CVEs hit our stack in 2025/2026 alone | Run it. Check the CVE dates. |
| "It's not deployed yet" | Code vulns exist in the repo regardless of deployment status | Audit the code, not the infra |
| "Tests pass so it's secure" | Tests verify functionality, not auth bypass or tenant isolation | Tests and security audits are orthogonal |
| "The prior audit found nothing critical" | March 2026 audit found 18 CRITICALs after 31 security PRs merged | Never trust "nothing found" |
| "It takes too long" | 10 parallel agents finish in ~10 minutes. Incident response takes weeks. | Run the audit |
| "Only Avi uses it" | One user with admin access IS the attack surface right now | Audit anyway |

---

## Phase 1: Reconnaissance

**Goal:** Understand what we're auditing before dispatching agents.

### Step 1.1: Detect Repository

Check if we're in the ottomatt repo:

```
Look for: docker-compose.prod.yml, services/, packages/db-utils/
If found: REPO_ROOT = current directory or C:/Users/Avi/Desktop/Ottomatt/ottomatt/
If not found: Ask Avi which repo to audit
```

### Step 1.2: Enumerate Services

```bash
ls {REPO_ROOT}/services/
```

Store the live service list. Agent briefs reference `{SERVICES}` which gets filled from this.

### Step 1.3: Check Prior Audit

```bash
ls {REPO_ROOT}/security-audit-*.html 2>/dev/null
```

If found, read the executive summary to enable delta comparison (NEW/RECURRING/RESOLVED/REGRESSED).

### Step 1.4: Check Concurrent Sessions

```bash
tasklist | findstr claude | wc -l
```

Calculate available agent slots: `10 - active_count`. Plan waves accordingly.

### Step 1.5: Read Reference Files

Read these from `{baseDir}/references/`:
- `workstream-briefs.md` (agent briefs)
- `cve-2026-checks.md` (CVE patterns)
- `tob-integration-map.md` (Trail of Bits methodology excerpts)
- `finding-schema.json` (output schema)

### Step 1.6: Create Tasks

Use TaskCreate to create one task per workstream (11 tasks) plus:
- "Synthesis: collect and deduplicate findings"
- "Report: generate HTML + JSON output"

---

## Phase 2: Static Analysis Dispatch

**Goal:** Dispatch 10 parallel agents, each running one workstream.

### Wave Strategy

| Available Slots | Wave 1 | Wave 2 |
|-----------------|--------|--------|
| >= 10 | AUTH, RLS, INFRA, CI, SEC, EXT, INPUT, AI, RATE, MISC | PII |
| 5 to 9 | AUTH, RLS, INFRA, CI, SEC | EXT, INPUT, AI, RATE, MISC, PII |
| < 5 | AUTH, RLS, INFRA | CI, SEC, EXT then INPUT, AI, RATE, MISC, PII |

### Agent Dispatch

For each workstream, dispatch an Agent with:
- `model: "sonnet"` (execution task)
- Brief from `references/workstream-briefs.md` (the section for that workstream)
- CVE checks from `references/cve-2026-checks.md` (if applicable)
- ToB methodology from `references/tob-integration-map.md` (if applicable)
- Output schema from `references/finding-schema.json`

**All agents in a wave MUST be dispatched in a single message** for true parallelism.

### Agent Brief Template

Each agent receives:

```
You are a security auditor running workstream {ID}: {NAME}.

Repository: {REPO_ROOT}
Services: {SERVICES_LIST}

## Files to Read (ALL mandatory before reporting)
{FILE_LIST from workstream-briefs.md}

## Checks (execute ALL, report PASS/FAIL/NA with evidence)
{CHECK_LIST from workstream-briefs.md}

## 2026 CVE Checks
{CVE_CHECKS from cve-2026-checks.md, if any for this workstream}

## Trail of Bits Methodology
{TOB_EXCERPT from tob-integration-map.md}

## Output Format
Return valid JSON matching the finding schema. Every check must have:
- id, name, status (PASS/FAIL/NA)
- severity (CRITICAL/HIGH/MEDIUM/LOW, null if PASS)
- files examined, evidence with line numbers
- suggestedFix if FAIL

Do NOT report PASS without reading actual code.
Do NOT hallucinate file paths or line numbers.
```

### After Dispatch

- Update each task to "in_progress" via TaskUpdate
- Wait for all agents in the wave to complete
- Verify each returned valid JSON (if not, flag and note "incomplete workstream")
- Dispatch wave 2 if needed

---

## Phase 2.5: Dynamic Testing (optional)

**Only runs if `--pentest` flag was passed.**

Read `references/pentagi-integration.md` for PentAGI API integration details.

1. Check if PentAGI is running: `curl -s http://localhost:8080/api/health`
2. If available, feed static analysis findings as context
3. PentAGI runs nmap, sqlmap, etc. against staging
4. Collect results and tag findings as "CONFIRMED" (exploitable) vs "THEORETICAL"

If PentAGI is not available, skip with a note: "Dynamic testing skipped: PentAGI not running."

---

## Phase 3: Synthesis

**Goal:** Combine 10 workstream outputs into a unified finding set.

**Run this phase as Opus** (deep reasoning needed for attack path analysis).

### Step 3.1: Collect

Parse all 11 JSON outputs. Merge into a single findings array. Expected: 110-130 findings.

### Step 3.2: Deduplicate

Findings referencing the same `file:line` from different workstreams get merged. Keep the highest severity. Combine evidence from both.

### Step 3.3: Cross-Workstream Attack Paths

Look for compound chains that combine findings from different workstreams:

| Chain | Components | Impact |
|-------|-----------|--------|
| Tenant Data Exposure | AUTH bypass + RLS gap | Full cross-tenant read/write |
| Financial Fraud | Webhook forgery (EXT) + no idempotency (MISC) | Duplicate payments |
| AI Cross-Tenant | Tool gate bypass (AI) + missing tenant isolation (RLS) | Data leak via chat |
| Remote Code Execution | CI secret leak + exposed port (INFRA) | Full server compromise |
| Supply Chain RCE | Compromised dep (CI) + no lockfile integrity | Arbitrary code in build |

Each identified chain gets severity bumped to CRITICAL and highlighted in the report.

### Step 3.4: Delta Comparison

If prior audit exists (from Phase 1.3):
- Extract prior finding IDs and severities
- Mark each current finding: NEW, RECURRING, RESOLVED, REGRESSED
- Calculate: findings fixed since last audit, new findings, regressions

### Step 3.5: Second Opinion

Dispatch one final agent using the Trail of Bits `second-opinion` methodology:

"You are an adversarial reviewer. Here are the combined findings from 11 security audit workstreams. Your job: What did they miss? What was over-rated? What attack paths did they not connect? Be skeptical."

### Step 3.6: Score

```
score = 100 - (CRITICALs * 15) - (HIGHs * 5) - (MEDIUMs * 2) - (LOWs * 0.5) + (positives * 2)
score = max(0, min(100, score))
```

---

## Phase 4: Report Generation

**Goal:** Produce HTML report, JSON findings, and Telegram summary.

### Step 4.1: Generate HTML

Read `references/report-template.html` for the template. Fill in:
- Date, scope, method, services audited
- Executive summary with stat grid
- Findings sorted by severity (CRITICAL first)
- Attack paths with gold border
- Delta from prior audit
- Positives section
- Priority fix order
- Master finding table

**Branding rules (mandatory):**
- Font: Heebo (Google Fonts)
- Body text: `#16212B`
- Headings/secondary: `#1b465f`
- Accent/gold: `#c27d2f`
- Background: `#f6f1e8`
- CRITICAL badge: `#d32f2f`
- HIGH badge: `#e65100`
- MEDIUM badge: `#c27d2f`
- LOW badge: `#1b465f`
- PASS badge: `#2e7d32`
- NEVER use grey text (no `#475569`, `#64748b`, `#94a3b8`, etc.)

Save to: `{REPO_ROOT}/security-audit-{YYYY-MM-DD}.html`

### Step 4.2: Generate JSON

Save structured findings to: `{REPO_ROOT}/security-audit-{YYYY-MM-DD}.json`

### Step 4.3: Telegram Summary

Send via OttomattBot to chat_id 6659800746:

```
Security Audit Complete: {DATE}

Score: {SCORE}/100
CRITICAL: {N} | HIGH: {N} | MEDIUM: {N} | LOW: {N}
New: {N} | Recurring: {N} | Resolved: {N} | Regressed: {N}

Top finding: {MOST_CRITICAL_FINDING_TITLE}
Open the HTML report for full details.
```

---

## Phase 5: Wrap-up

1. Mark all tasks as completed via TaskUpdate
2. Tell Avi in plain English:
   - Security score and what it means
   - How many findings by severity
   - Top 3 things to fix first
   - What changed since last audit (if applicable)
   - What couldn't be verified (e.g., runtime checks needing SSH)

---

## Quick Reference

### Workstream IDs
AUTH, RLS, EXT, INFRA, CI, INPUT, AI, SEC, RATE, MISC

### Check ID Format
`{WORKSTREAM}-{NN}` (e.g., AUTH-01, RLS-10, INFRA-07)

### Severity Scale
CRITICAL > HIGH > MEDIUM > LOW > INFO

### Files Created
- `{REPO_ROOT}/security-audit-{YYYY-MM-DD}.html`
- `{REPO_ROOT}/security-audit-{YYYY-MM-DD}.json`

---

## Success Criteria

- [ ] All 10 workstreams dispatched and returned valid JSON
- [ ] Every check has PASS/FAIL/NA with evidence (no blanks)
- [ ] CVE checks include version numbers and PASS/FAIL
- [ ] HTML report renders correctly with Ottomatt branding
- [ ] No grey text anywhere in the report
- [ ] Attack paths section identifies at least 2 compound chains
- [ ] Delta comparison works if prior audit exists
- [ ] JSON findings file is valid and parseable
- [ ] Plain English wrap-up delivered to Avi
