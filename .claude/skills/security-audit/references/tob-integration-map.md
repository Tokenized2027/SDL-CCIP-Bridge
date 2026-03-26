# Trail of Bits Skill Integration Map

This file maps Trail of Bits security skills to audit workstreams and provides the methodology excerpts that get inlined into each agent's brief.

## Integration Approach

ToB skills are NOT invoked as separate processes. Their methodology is excerpted and inlined into each agent's brief. The agent follows the ToB workflow as part of its scan. This halves agent count and keeps within the Windows 10-agent limit.

---

## insecure-defaults

**Used by:** AUTH, INFRA, SEC, EXT

**Methodology to inline:**

Follow this 4-step workflow for finding fail-open vulnerabilities:

### 1. SEARCH: Find Insecure Defaults
Search for these patterns in config files, auth code, and environment handling:
- **Fallback secrets:** `process.env.XXX || 'default'`, `?? 'fallback'`, `.default('dev-...')`
- **Hardcoded credentials:** `password = '...'`, `apiKey = '...'`, `secret = '...'`
- **Weak defaults:** `DEBUG = true`, `AUTH_ENABLED = false`, `CORS_ORIGIN = '*'`
- **Crypto weaknesses:** MD5, SHA1, DES, RC4, ECB in security contexts

Focus on production-reachable code. Skip test fixtures and example files.

### 2. VERIFY: Trace Runtime Behavior
For each match, answer:
- When is this code executed? (Startup vs runtime)
- What happens if the env var is missing?
- Is there validation that enforces secure configuration?

### 3. CONFIRM: Production Impact
- If production config provides the variable: Lower severity (but still code-level vuln)
- If production config is missing or uses default: CRITICAL
- **Fail-open** (CRITICAL): `SECRET = env.get('KEY') || 'default'` (app runs with weak secret)
- **Fail-secure** (SAFE): `SECRET = env['KEY']` (app crashes if missing)

### 4. REPORT: With Evidence
Include file path, line number, the vulnerable pattern, what happens in production, and specific fix.

---

## sharp-edges

**Used by:** AUTH, EXT, INPUT, RATE

**Methodology to inline:**

Evaluate APIs and configurations for "pit of success" violations. The secure path should be the easiest path.

### Categories to Check

**1. Algorithm/Mode Selection Footguns:**
- Can users/callers choose cryptographic algorithms? (JWT alg header, hash function parameter)
- If yes: can they choose `none`, weak algorithms, or trigger algorithm confusion?
- The JWT Pattern: header-controlled algorithm = attacker-controlled security decision

**2. Dangerous Defaults:**
- What happens when timeout/lifetime = 0? (infinite? immediate expiry? undefined?)
- What happens when a limit is not set? (unlimited? zero? error?)
- Are security features opt-in (dangerous) or opt-out (safer)?

**3. Configuration Footguns:**
- Can a single misconfiguration disable all security?
- Are dangerous config combinations validated and rejected?
- Do error messages help developers fix misconfigurations?

### Rationalizations to Reject
| Rationalization | Reality |
|---|---|
| "It's documented" | Developers don't read docs under deadline pressure |
| "Advanced users need flexibility" | Most "advanced" usage is copy-paste |
| "It's the developer's responsibility" | You designed the footgun |
| "Nobody would actually do that" | They will, under pressure |

---

## supply-chain-risk-auditor

**Used by:** CI, MISC

**Methodology to inline:**

Evaluate all direct dependencies for supply chain risk. A dependency is high-risk if:

1. **Single maintainer** (especially anonymous): phishing/bribery = malicious publish
2. **Unmaintained**: no updates for 12+ months, large unresolved issue count, deprecated
3. **Low popularity**: few stars/downloads relative to peers (fewer eyes = slower detection)
4. **High-risk features**: FFI, deserialization, third-party code execution
5. **Past CVEs**: high/critical severity CVEs, especially relative to complexity
6. **No security contact**: no SECURITY.md, no security email, no bug bounty

### Workflow
1. Find all git repositories for direct dependencies
2. For each, evaluate risk criteria using `gh api` for accurate data (stars, issues, maintainer count)
3. Flag high-risk deps with specific risk factors
4. Suggest alternatives where available
5. Summarize overall supply chain posture

---

## agentic-actions-auditor

**Used by:** CI, AI

**Methodology to inline:**

Audit for untrusted-input-to-privileged-action chains.

### For CI workstream (GitHub Actions):
1. Find all workflow files (.github/workflows/*.yml)
2. Identify AI action steps (claude-code-action, gemini, codex)
3. Check trigger events: `pull_request_target`, `issue_comment` expose to external input
4. Trace data flow: `${{ github.event.* }}` -> `env:` blocks -> prompt fields
5. Check sandbox config: `danger-full-access`, `Bash(*)`, `--yolo` = disabled protections
6. Check user allowlists: wildcard `*` = any user can trigger

### For AI workstream (Tool Loop):
Adapt the same pattern: untrusted user message -> tool selection -> privileged action.
1. Can user input influence which tools are called?
2. Can tool results inject instructions that cause escalated actions?
3. Are tool permissions scoped per agent type?
4. Is there a human-in-the-loop for destructive actions?

### Key Vectors to Check
- Environment variable intermediary (data flows through env: to prompt, no visible ${{ }})
- Direct expression injection in `run:` steps
- Composite action hiding (AI agent in a referenced composite action)

---

## variant-analysis

**Used by:** RLS, INPUT

**Methodology to inline:**

After finding ONE vulnerability instance, systematically find ALL similar instances.

### 5-Step Process
1. **Understand the original:** What is the root cause? What conditions are required?
2. **Create exact match:** Pattern that matches ONLY the known instance
3. **Identify abstraction points:** What can be generalized? (variable names = always abstract, function names = abstract if pattern applies broadly)
4. **Iteratively generalize:** Change ONE element at a time. Run. Review all new matches. Stop when false positive rate exceeds ~50%.
5. **Triage results:** Location, confidence (High/Medium/Low), exploitability, priority

### For RLS workstream:
After finding one missing tenantId filter, generalize the pattern to find ALL queries that:
- Use `.where()` without tenantId
- Access tenant-scoped tables directly (bypassing RLS)
- Use `runAsAdmin` in user-facing code paths

### For INPUT workstream:
After finding one unvalidated route, generalize to find ALL routes that:
- Accept POST/PUT/PATCH without Zod validation
- Use `req.body` without schema parsing
- Pass user input to `sql.raw()` or template literals

---

## entry-point-analyzer

**Used by:** INFRA

**Methodology to inline (adapted from smart contracts to HTTP services):**

Map all network entry points to understand the attack surface.

### Workflow
1. **Enumerate ports:** Check docker-compose for all `ports:` entries
2. **Map Caddy routes:** Parse Caddyfile for all `route`, `handle`, `reverse_proxy` directives
3. **Identify public endpoints:** Routes NOT behind auth middleware
4. **Classify access levels:**
   - PUBLIC: No auth required (health, webhooks, landing pages)
   - AUTHENTICATED: Requires valid JWT/session
   - INTERNAL: Requires X-Internal-Secret
   - ADMIN: Requires platform admin secret

### Output
Table with: Endpoint, Method, Service, Access Level, Auth Mechanism

---

## second-opinion (Synthesis Phase Only)

**Used by:** Synthesis phase after all 10 workstreams complete

**Methodology to inline:**

You are an adversarial reviewer. Your job is to challenge the combined findings from 10 security audit workstreams.

### Questions to Answer
1. **What was missed?** Are there obvious attack vectors not covered by any workstream?
2. **What was over-rated?** Are any CRITICAL findings actually lower severity given the deployment context?
3. **What attack paths were not connected?** Look for chains across workstreams that individual agents wouldn't see.
4. **What assumptions were wrong?** Did agents assume files exist that don't? Did they assume configurations are applied that aren't?
5. **What's the biggest risk?** If you were attacking this system, where would you start?

### Output
- List of missed areas (if any)
- Severity adjustments (upgrade or downgrade specific findings with justification)
- Additional attack paths not identified by individual workstreams
- Overall risk assessment in one paragraph

---

## audit-context-building (Optional, --deep flag only)

**Used by:** Pre-Phase 2, only if --deep flag passed

**Methodology to inline:**

Before dispatching workstream agents, build ultra-granular context on the 3 most critical services:
1. `packages/db-utils/` (shared auth and RLS)
2. `services/ai-assistant/` (AI security)
3. `services/portal/` (user-facing attack surface)

For each: read every file, build a call graph, identify trust boundaries, map data flows. This takes 5-10 minutes but produces deeper findings.

Not recommended for routine audits. Use for pre-launch or post-incident deep dives.
