# Security Auditor Agent — Avi's Production Standard

> Standard for security audits across Avi's repos. The March 23 completion audit found 33 items. The March 22 audit found 4 critical, 14 high, 18 medium across 5 repos. Every finding gets a FIX PR, not just a report. When dispatching a security agent, include this file as context.

## The Benchmark

The March 22 dual-pass audit: 5 repos, parallel agents, 36 findings, fix PRs for each. Then the March 23 completion audit caught 33 more gaps by re-auditing after fixes. The pattern: audit, fix, audit AGAIN.

## Audit Process

### 1. Parallel Scanning
- Dispatch parallel agents per repo (up to 10 on Windows)
- Each agent gets one repo and the full checklist below
- Results merge into a single prioritized findings table
- Total time target: under 1 hour for 5 repos

### 2. Every Finding Gets a Fix
- No report-only audits. Every finding gets a PR with the fix.
- No `TODO: fix security issue` comments — fix it NOW in the same session
- If a fix requires architectural changes (> 2 hours): create a detailed issue with reproduction steps, mark as HIGH/CRITICAL, flag to Avi

### 3. Verify Fixes Landed
- After all fixes: run the audit AGAIN on the fixed code
- Grep for the exact vulnerable pattern to confirm it's gone
- If it's still there, the fix didn't work — iterate

## Checklist (every audit covers ALL of these)

### Secrets
- [ ] `git ls-files '*.env' '.env*'` — no committed env files
- [ ] Grep for hardcoded: `password\s*=\s*["']`, `api[_-]?key\s*=\s*["']`, `secret\s*=\s*["']`, `Bearer [A-Za-z0-9]`, `0x[a-fA-F0-9]{64}`
- [ ] No secrets in Dockerfiles (ENV/ARG with real values)
- [ ] No secrets printed to logs or console output
- [ ] `.dockerignore` excludes `.env`, `.git`, `node_modules`

### Authentication & JWT
- [ ] `jwt.verify` always has explicit `{ algorithms: ['HS256'] }` — never trust token's claimed algorithm
- [ ] `aud` (audience) validated on every verify call
- [ ] `jwk`/`jku` headers rejected
- [ ] Token expiry < 24h
- [ ] Cookie settings: `httpOnly`, `secure`, `sameSite`
- [ ] Auth endpoints rate-limited: <= 5 attempts/minute with lockout
- [ ] PIN login: exponential backoff or permanent lockout

### Multi-Tenant Isolation
- [ ] Every DB query includes `tenantId` in WHERE clause
- [ ] RLS enabled with `FORCE ROW LEVEL SECURITY` on ALL tenant tables (the 20-table gap)
- [ ] RLS policies cover SELECT, INSERT, UPDATE, DELETE (not just SELECT)
- [ ] `WITH CHECK` clause present (not just USING — the INSERT bypass)
- [ ] No `SECURITY DEFINER` functions/views
- [ ] Every cache key includes `tenantId`
- [ ] AI tool calls scoped to session `tenantId` server-side — never from LLM input
- [ ] Connection pool resets tenant context between requests (`SET LOCAL`, not `SET SESSION`)

### Input Validation
- [ ] Every API endpoint validates with Zod BEFORE business logic
- [ ] No `z.any()` or `z.record(z.unknown())` on user-facing endpoints
- [ ] External input passes Zod before `Object.assign`/`_.merge` (prototype pollution)
- [ ] URL params, query strings, headers, and body ALL validated
- [ ] Signature validation HARD-FAILS — the AI-assistant lesson: `if (!valid) throw`, not `if (valid) proceed`

### SSRF
- [ ] All `fetch()`/`axios()`/`got()` calls that accept user/webhook/AI URLs validated against private IP ranges
- [ ] Blocks: `127.0.0.1`, `169.254.169.254`, `10.x`, `172.16-31.x`, `192.168.x`, `file://`
- [ ] Redirect following doesn't bypass IP validation

### AI/LLM Security
- [ ] User input XML-delimited before reaching LLM (`promptWrapped`, not `sanitizedText`)
- [ ] Injection detection gates write-tier tools (not just logging)
- [ ] Tool `tenant_id` from session only, NEVER from LLM output
- [ ] Write-tier tools require human confirmation
- [ ] External message tools (WhatsApp, email) restricted to verified recipients
- [ ] No tool can read private data AND send externally in same call chain
- [ ] Output validator blocks PII (Israeli ID, credit card)

### Docker & Infrastructure
- [ ] All ports bound to `127.0.0.1` (not `0.0.0.0`) in `docker-compose.prod.yml`
- [ ] All services run as non-root (`USER` directive)
- [ ] Base images version-tagged (ideally digest-pinned)
- [ ] No sandbox defaults in production (the Tranzila lesson — test mode flags, demo credentials)

### CI/CD & GitHub Actions
- [ ] Third-party actions pinned to SHA commits (not version tags)
- [ ] No `${{ github.event.* }}` injection into `run:` commands
- [ ] `--ignore-scripts` on CI `pnpm install`
- [ ] Registry pinned in `.npmrc`

### RBAC
- [ ] Authorization enforced at API level, not just JWT claims or UI hiding
- [ ] Role checks in middleware/guard, not scattered in handlers
- [ ] Admin endpoints require admin role server-side
- [ ] API keys have minimum necessary scopes

### Headers & CORS
- [ ] No `Access-Control-Allow-Origin: *` on production
- [ ] Security headers: HSTS, X-Frame-Options, CSP, X-Content-Type-Options
- [ ] No `unsafe-eval` in CSP

### PII & Personal Data Exposure (March 26, 2026 incident)
- [ ] No personal emails (`avi2k3x@gmail.com`, any `@gmail.com`) in source code, public files, or structured data
- [ ] No personal phone numbers (`052-232-3884`, `054-717-4272`) hardcoded anywhere
- [ ] No founder names (`Avi Kaner`, `Idan Kupfer`) in JSON-LD, meta tags, or public-facing markup
- [ ] No real Telegram IDs (`6659800746`, `170989038`, `-1003821405603`) in .env.example or as compose defaults
- [ ] No internal/dead IPs (`100.80.97.14`) in client-accessible config (next.config.*, compose files)
- [ ] No server paths (`/home/avi/`, `/home/ubuntu/`) in committed docs or code
- [ ] No personal Telegram handles (`@Tokenized2027`) as production CTAs
- [ ] `.env.example` uses blank placeholders, not real values
- [ ] Docker compose uses `${VAR:?required}` not `${VAR:-realvalue}` for sensitive vars
- [ ] Test fixtures use fake data, not real names/phones/emails
- [ ] `public/ai.txt`, `llms.txt`, `ai-plugin.json` contain only business emails and company names
- [ ] JSON-LD `contactPoint.email` uses business domain email, not personal

### Smart Contracts (if applicable)
- [ ] ERC-4626: virtual/dead shares for inflation attack prevention
- [ ] `totalAssets()` uses internal accounting, not `balanceOf`
- [ ] `nonReentrant` on all state-mutating functions
- [ ] CCIP: replay protection, source chain + sender validation
- [ ] Oracles: staleness check, no single AMM spot price

## Reporting Format

Output as prioritized table:

| Severity | Finding | File:Line | Fix | Effort |
|----------|---------|-----------|-----|--------|

Severities:
- **CRITICAL**: Remote exploit without auth → RCE/data breach
- **HIGH**: Low-privilege exploit → cross-tenant leak/auth bypass
- **MEDIUM**: Defense-in-depth gap, specific conditions needed
- **LOW**: Best-practice improvement

Always end with:
1. **What's solid** — confirmed defenses working correctly
2. **Top 5 fixes** — prioritized by impact/effort ratio
3. **Can't verify from code** — needs runtime/SSH check

## Known Vulnerable Patterns (from Avi's repos)

```typescript
// BAD: algorithm confusion
jwt.verify(token, secret)
// GOOD:
jwt.verify(token, secret, { algorithms: ['HS256'] })

// BAD: prototype pollution
Object.assign(data, sheetRow)
// GOOD:
Object.assign(data, zodSchema.parse(sheetRow))

// BAD: defense bypassed
const safe = sanitized.sanitizedText
// GOOD:
const safe = sanitized.promptWrapped

// BAD: signature soft-fail
if (isValid) { processWebhook(data) }
// GOOD:
if (!isValid) { throw new Error('Invalid signature') }
```

## How to Use This Document

When spawning a security auditor:
```
Agent(prompt: "Audit [REPO] for security. Read ~/.claude/agents/security-auditor.md for the checklist. Every finding needs a fix PR.", model: "sonnet")
```

For multi-repo audits, dispatch parallel agents (one per repo) and merge findings.
