# Ottomatt Security Audit: Workstream Agent Briefs

Each section below is injected into an agent prompt when that workstream is dispatched.
Repo root: `C:/Users/Avi/Desktop/Ottomatt/ottomatt/`

---

# WS1: AUTH (Authentication Chain)

Scope: Every route in every service. Verify each endpoint is protected by correct middleware. No endpoint should be accidentally public.

## Files to Read

- packages/db-utils/src/internal-auth.ts
- packages/db-utils/src/middleware-factory.ts
- services/core/src/auth.ts
- services/core/src/routes/auth.ts
- services/portal/lib/auth.ts
- services/portal/lib/admin-auth.ts
- services/portal/middleware.ts
- services/*/src/middleware.ts (all service middleware files)
- caddy/Caddyfile

## Checks

1. **AUTH-01: JWT algorithm pinning.** Must use `algorithms: ['HS256']` (array form). PASS: explicitly set. FAIL: allows none or RS256.
2. **AUTH-02: JWT secret strength.** Production must reject default/empty secrets. PASS: fails if missing. FAIL: accepts defaults.
3. **AUTH-03: Session token revocability.** Check if stateless JWTs can be revoked. PASS: revocation mechanism exists. FAIL: no revocation possible.
4. **AUTH-04: Password hashing.** Must use bcrypt with cost >= 12 for passwords, >= 10 for PINs. PASS: correct algorithm and cost. FAIL: weak hashing.
5. **AUTH-05: Reset token security.** Must use HMAC-SHA256, time-limited. PASS: secure generation and expiry. FAIL: plain storage or no expiry.
6. **AUTH-06: Internal auth on every service route.** No routes bypassing internalAuth middleware. PASS: all non-health/webhook routes have auth. FAIL: any route reachable without auth.
7. **AUTH-07: Service secret isolation.** Per-service secrets, not global fallback. PASS: isolated secrets. FAIL: shared secret across services.
8. **AUTH-08: Timing-safe comparison on all secret validation paths.** PASS: uses timingSafeEqual or safeCompare. FAIL: uses === for secrets.
9. **AUTH-09: Admin auth escalation.** Non-admins cannot access /admin/* routes. PASS: admin middleware enforced. FAIL: accessible without admin role.
10. **AUTH-10: CORS configuration.** Not wildcard (*) in production. PASS: specific origins only. FAIL: allows all origins.
11. **AUTH-11: CVE-2025-29927 (Next.js middleware bypass).** Check x-middleware-subrequest header stripped by Caddy AND Next.js version >= 15.2.3. PASS: both mitigated. FAIL: either missing.
12. **AUTH-12: CVE-2026-22817 + CVE-2026-29045 (Hono JWT confusion + serveStatic bypass).** Check hono version >= 4.12.4. PASS: patched version. FAIL: vulnerable version.

---

# WS2: RLS (Tenant Isolation)

Scope: Verify every database query is tenant-scoped via RLS. TenantId cannot be spoofed. No cross-tenant data leakage possible.

## Files to Read

- packages/db-utils/src/tenant-context.ts
- packages/db-utils/src/rls.ts (if exists)
- scripts/apply-rls.sh (if exists)
- scripts/rls-migrations/*.sql (if exists)
- services/*/src/schema.ts (all schemas)
- services/*/src/queries.ts or services/*/src/queries/*.ts
- docker-compose.prod.yml (postgres user config)
- .env.example

## Checks

1. **RLS-01: Every table with tenant_id has FORCE ROW LEVEL SECURITY enabled.** PASS: all tenant tables have it. FAIL: any missing.
2. **RLS-02: RLS policies exist (CREATE POLICY, not just ENABLE RLS).** PASS: policies defined. FAIL: RLS enabled but no policies.
3. **RLS-03: Services connect as non-superuser (ottomatt_app).** PASS: app role used. FAIL: superuser connection.
4. **RLS-04: POSTGRES_ALLOW_APP_ROLE_ADMIN_ESCALATION is false in production.** PASS: false or not set. FAIL: true.
5. **RLS-05: runAsAdmin usage justified (health checks, migrations, admin queries only).** PASS: all usages justified. FAIL: runAsAdmin in user-facing code paths.
6. **RLS-06: No raw SQL bypassing tenant_id filters.** PASS: all queries use ORM with RLS. FAIL: manual WHERE clauses that could miss tenantId.
7. **RLS-07: Unique constraints are tenant-composite.** PASS: unique(tenant_id, field). FAIL: globally unique without tenant scope.
8. **RLS-08: Proxy delegation in createTenantAwareProxy is hermetic.** PASS: no store-miss bypass. FAIL: fallback path skips tenant check.
9. **RLS-09: tenantId validation regex prevents SQL injection.** PASS: strict alphanumeric regex. FAIL: allows special characters.
10. **RLS-10: CVE-2025-8713 (PostgreSQL RLS bypass via optimizer).** Check PG version >= 16.7 or 17.3. PASS: patched version. FAIL: vulnerable.
11. **RLS-11: Cross-schema isolation.** No JOINs across pgSchema boundaries. PASS: schemas isolated. FAIL: cross-schema queries.
12. **RLS-12: Admin panel uses callServiceAsAdmin for cross-tenant ops.** PASS: proper admin delegation. FAIL: user-context used for admin ops.

---

# WS3: EXT (External Integrations)

Scope: All external API integrations. Proper auth, error handling, secret management, SSRF protections.

## Files to Read

- services/connections/src/routes/webhooks/*.ts
- services/connections/src/routes/onboarding-connect.ts
- services/connections/src/routes/social.ts
- services/billing/src/routes/payment-gateway.ts (if exists)
- services/billing/src/routes/green-invoice.ts (if exists)
- services/connections/src/schema.ts
- services/ai-assistant/src/tools-service-client.ts
- packages/db-utils/src/network-security.ts (if exists)
- packages/db-utils/src/url-validator.ts (if exists)

## Checks

1. **EXT-01: Webhook signature verification on all inbound webhooks (Tranzila, PayBox, Green Invoice, Meta).** PASS: all verified. FAIL: any missing verification.
2. **EXT-02: OAuth token storage encrypted at rest, refresh token handling secure.** PASS: encrypted. FAIL: plaintext storage.
3. **EXT-03: SSRF protection on outbound HTTP calls.** URL validation blocks private IPs, localhost, internal Docker hostnames. PASS: validated. FAIL: unvalidated URLs.
4. **EXT-04: Idempotency keys on webhook handlers.** PASS: duplicate detection exists. FAIL: replays processed.
5. **EXT-05: Payment callback server-side verification.** PASS: verifies with payment provider. FAIL: trusts client-side callback.
6. **EXT-06: API key rotation mechanism exists.** PASS: documented rotation path. FAIL: no rotation mechanism.
7. **EXT-07: Webhook IP allowlisting.** PASS: configured. FAIL: accepts from any IP.
8. **EXT-08: Rate limiting on public webhook endpoints.** PASS: rate limited. FAIL: unlimited.
9. **EXT-09: OAuth state parameter validation (CSRF prevention).** PASS: state validated. FAIL: no state parameter.
10. **EXT-10: External API error handling.** No secret leakage in error responses. PASS: secrets stripped. FAIL: keys in errors.

---

# WS4: INFRA (Docker/Infrastructure)

Scope: Docker configs, network isolation, resource limits, Caddy reverse proxy.

## Files to Read

- docker-compose.prod.yml
- docker-compose.staging.yml
- docker-compose.yml
- Dockerfile.service
- Dockerfile.portal
- Dockerfile.website (if exists)
- Dockerfile.alma (if exists)
- Dockerfile.postgres
- Dockerfile.caddy
- caddy/Caddyfile
- Caddyfile.staging (if exists)
- docker/pgbouncer/pgbouncer.ini (if exists)
- shared.env
- .dockerignore

## Checks

1. **INFRA-01: No 0.0.0.0 port bindings.** Only Caddy exposes 80/443. PASS: internal only. FAIL: service ports exposed.
2. **INFRA-02: Docker healthchecks on all services.** PASS: all have healthcheck. FAIL: any missing.
3. **INFRA-03: Resource limits (mem_limit, cpus) set on all containers.** PASS: all limited. FAIL: unlimited containers.
4. **INFRA-04: Redis requires password (--requirepass), dangerous commands renamed.** PASS: password required. FAIL: no auth.
5. **INFRA-05: PostgreSQL not exposed outside Docker network.** PASS: internal only. FAIL: host port binding.
6. **INFRA-06: Caddy security headers (HSTS, X-Frame-Options, CSP).** PASS: all present and correct. FAIL: missing headers.
7. **INFRA-07: CVE-2025-55182/CVE-2025-66478 (Next.js RSC RCE, CVSS 10.0).** Check next version in portal package.json >= 15.3.1. PASS: patched. FAIL: vulnerable.
8. **INFRA-08: CVE-2026-30851 (Caddy forward_auth bypass).** Check Caddy version in Dockerfile.caddy >= 2.11.2. PASS: patched. FAIL: vulnerable.
9. **INFRA-09: CVE-2025-31133 (runc container escape).** Note: requires SSH to check Docker version on host. Mark as "REQUIRES_RUNTIME_CHECK" if can't verify.
10. **INFRA-10: pgBouncer authentication configured.** PASS: auth required. FAIL: no auth.
11. **INFRA-11: x-middleware-subrequest header stripped by Caddy.** Check Caddyfile for request_header removal. PASS: stripped. FAIL: passes through.
12. **INFRA-12: No .env files baked into Docker images.** Check .dockerignore excludes .env*. PASS: excluded. FAIL: could be included.

---

# WS5: CI (CI/CD Pipeline)

Scope: GitHub Actions workflows, secrets exposure, workflow injection, runner security, supply chain.

## Files to Read

- .github/workflows/*.yml (all workflow files)
- .githooks/pre-push (if exists)
- package.json (scripts section)
- .gitignore
- .dockerignore
- scripts/deploy-waves.sh (if exists)
- scripts/verify-deploy.sh (if exists)
- pnpm-lock.yaml (for chalk/debug versions)

## Checks

1. **CI-01: No hardcoded secrets in workflow files.** PASS: all via ${{ secrets.XXX }}. FAIL: plaintext secrets.
2. **CI-02: Third-party actions pinned to SHA hashes (not mutable tags).** PASS: SHA-pinned. FAIL: uses @v4 etc.
3. **CI-03: Workflow permissions are minimal.** PASS: contents: read. FAIL: write or admin.
4. **CI-04: No pull_request_target with checkout of PR head.** PASS: safe trigger config. FAIL: code injection vector.
5. **CI-05: Pre-push hook blocks direct push to main.** PASS: hook exists and enforces. FAIL: no protection.
6. **CI-06: pnpm audit runs in CI with --audit-level=high.** PASS: blocks on vulnerabilities. FAIL: no audit or doesn't block.
7. **CI-07: September 2025 chalk/debug supply chain.** Check pnpm-lock.yaml for chalk and debug versions not in compromised range. PASS: safe versions. FAIL: compromised versions.
8. **CI-08: .env not committed to git.** PASS: in .gitignore. FAIL: tracked or missing from gitignore.
9. **CI-09: Deploy scripts use SSH keys, not hardcoded passwords.** PASS: key-based auth. FAIL: password auth.
10. **CI-10: No --no-verify in any scripts.** PASS: hooks always run. FAIL: hooks bypassed.

---

# WS6: INPUT (Input Validation)

Scope: All input validation across all services. Zod schema coverage, SQL injection, XSS, template injection.

## Files to Read

- services/*/src/validation.ts (all validation files)
- services/connections/src/routes/webhooks/schemas.ts (if exists)
- services/portal/app/api/**/route.ts (sample 10-15 API routes)
- services/core/src/routes/*.ts
- services/billing/src/routes/*.ts
- packages/db-utils/src/tenant-context.ts
- services/portal/components/**/*.tsx (sample for XSS check)

## Checks

1. **INPUT-01: Every POST/PUT/PATCH route validates body with Zod before processing.** PASS: 100% coverage. FAIL: any unvalidated endpoint.
2. **INPUT-02: No raw req.body usage without schema validation.** PASS: all validated. FAIL: raw body access.
3. **INPUT-03: SQL injection prevention.** No string concatenation in queries, all via Drizzle ORM. PASS: parameterized. FAIL: string interpolation.
4. **INPUT-04: XSS vectors.** No dangerouslySetInnerHTML without sanitization. PASS: sanitized or not used. FAIL: unsanitized HTML rendering.
5. **INPUT-05: Path traversal prevention in file handlers.** PASS: paths sanitized. FAIL: user input in file paths.
6. **INPUT-06: Integer overflow on pagination/limit params (max bounds enforced).** PASS: bounded. FAIL: unbounded.
7. **INPUT-07: Content-Type enforcement.** Rejects non-JSON where expected. PASS: enforced. FAIL: accepts anything.
8. **INPUT-08: Request body size limits.** Caddy max_size + per-route limits. PASS: limits set. FAIL: unlimited.
9. **INPUT-09: tenantId format validation.** Regex check before DB query. PASS: validated. FAIL: unvalidated.
10. **INPUT-10: File upload validation (type, size, name sanitization).** PASS: validated. FAIL: unvalidated uploads.

---

# WS7: AI (AI Security)

Scope: AI assistant multi-layer defense. Prompt injection, data exfiltration, tool abuse, cross-tenant leakage.

## Files to Read

- services/ai-assistant/src/security.ts
- services/ai-assistant/src/tool-loop.ts (if exists)
- services/ai-assistant/src/tools.ts
- services/ai-assistant/src/tools-executor.ts (if exists)
- services/ai-assistant/src/config.ts
- packages/ai-foundation/ (if exists, scan for prompts and security)
- packages/prompts/ (if exists)
- services/ai-assistant/src/routes/*.ts

## Checks

1. **AI-01: Prompt injection detection exists and covers known patterns.** PASS: comprehensive patterns. FAIL: missing or basic.
2. **AI-02: Tool gate enforces allowlists.** Not all tools available to all agents. PASS: allowlist enforced. FAIL: unrestricted tool access.
3. **AI-03: Tool results defanged before feeding back to LLM.** PASS: defanging applied. FAIL: raw results passed.
4. **AI-04: tenantId injected from session, never from LLM output.** PASS: server-side injection. FAIL: LLM can control tenant context.
5. **AI-05: Max token limits enforced per request.** PASS: limits configured. FAIL: unlimited.
6. **AI-06: Write action limits enforced (maxWriteActions).** PASS: limited. FAIL: unlimited writes.
7. **AI-07: Tool mode enforcement (readonly vs readwrite).** PASS: modes enforced. FAIL: always readwrite.
8. **AI-08: Cross-agent signal validation.** Reject malformed signals. PASS: validated. FAIL: accepts arbitrary signals.
9. **AI-09: No shell execution tools exposed to chat agents.** PASS: shell blocked. FAIL: shell access available.
10. **AI-10: API key not exposed in tool results or error messages.** PASS: stripped. FAIL: leaked.

---

# WS8: SEC (Secret Management)

Scope: All secret handling. Hardcoded values, unsafe defaults, env var validation, log exposure.

## Files to Read

- .env.example
- shared.env
- .gitignore
- .dockerignore
- services/*/src/config.ts (all service configs)
- docker-compose.prod.yml
- docker-compose.staging.yml
- services/core/src/crypto.ts (if exists)
- services/connections/src/crypto.ts (if exists)

## Checks

1. **SEC-01: No hardcoded API keys, passwords, or tokens in source code.** Grep for sk-, xoxb-, Bearer with string literals. PASS: none found. FAIL: hardcoded secrets.
2. **SEC-02: All secrets use ${VAR:?required} pattern in docker-compose.** PASS: fail if missing. FAIL: uses ${VAR:-default}.
3. **SEC-03: .env in both .gitignore and .dockerignore.** PASS: excluded from both. FAIL: missing from either.
4. **SEC-04: Per-service secrets configured, not all sharing INTERNAL_SERVICE_SECRET.** PASS: isolated. FAIL: shared.
5. **SEC-05: Dev fallback secrets only in dev mode.** Production guards reject defaults. PASS: fail-secure. FAIL: defaults accepted in prod.
6. **SEC-06: No secrets in CI workflow files or logs.** PASS: none found. FAIL: secrets in workflows.
7. **SEC-07: ANTHROPIC_API_KEY not passed to subprocess environments.** PASS: not in subprocess env. FAIL: propagated to subprocesses.
8. **SEC-08: Database passwords use strong generation.** PASS: random, long passwords. FAIL: weak or default passwords.
9. **SEC-09: Secret rotation procedure documented or exists.** PASS: documented. FAIL: no rotation path.
10. **SEC-10: No secrets in Telegram messages or error logs.** PASS: stripped. FAIL: leaked in logs/messages.

---

# WS9: RATE (Rate Limiting/DoS/Sessions)

Scope: Rate limiting coverage, session lifecycle, concurrent sessions, resource exhaustion.

## Files to Read

- packages/db-utils/src/rate-limiter.ts
- services/*/src/middleware.ts (rate limit configs per service)
- services/core/src/middleware.ts
- caddy/Caddyfile (Caddy-level limits)
- services/portal/lib/auth.ts (session config)
- docker-compose.prod.yml (Redis config, maxmemory)
- services/portal/middleware.ts

## Checks

1. **RATE-01: Rate limiting on auth endpoints (login, register, reset).** PASS: stricter limits (e.g. 5/min). FAIL: no rate limit or too permissive.
2. **RATE-02: Rate limiting on API endpoints.** Per-tenant, not just global. PASS: tenant-scoped. FAIL: global only or missing.
3. **RATE-03: Redis-backed distributed rate limiting (not just in-memory).** PASS: Redis-backed. FAIL: in-memory only.
4. **RATE-04: Caddy request body size limits.** PASS: max_size configured. FAIL: unlimited.
5. **RATE-05: Session expiry configured.** Not infinite JWT lifetime. PASS: expiry set (e.g. 8h). FAIL: no expiry.
6. **RATE-06: Concurrent session limits.** PASS: limited. FAIL: unlimited sessions per user.
7. **RATE-07: CVE-2025-59466 (Node.js AsyncLocalStorage crash).** Check node version >= 22.14 or 20.18. PASS: patched. FAIL: vulnerable.
8. **RATE-08: Redis maxmemory policy.** PASS: noeviction or allkeys-lru. FAIL: no policy.
9. **RATE-09: Health endpoints excluded from rate limiting.** PASS: excluded. FAIL: health checks rate limited.
10. **RATE-10: Graceful degradation when Redis unavailable.** Fallback to in-memory. PASS: fallback exists. FAIL: crashes without Redis.

---

# WS10: MISC (Webhooks/Crons/Dependencies/Misc)

Scope: Webhook verification, cron job auth, dependency vulns, CSRF, file uploads, misc security items.

## Files to Read

- services/connections/src/routes/webhooks/*.ts
- services/connections/src/middleware.ts
- services/intelligence/src/scheduler.ts (if exists)
- services/*/src/crons/ (if exists)
- package.json
- pnpm-lock.yaml
- services/documents/src/routes/ (if exists)

## Checks

1. **MISC-01: Webhook handlers validate source (signature, IP, nonce).** PASS: all verified. FAIL: any unverified.
2. **MISC-02: Cron jobs run with minimal permissions.** PASS: scoped. FAIL: admin context.
3. **MISC-03: No known vulnerable dependencies.** Run pnpm audit mentally by checking package.json versions. PASS: no critical/high. FAIL: known vulns.
4. **MISC-04: Logging does not leak PII or secrets.** PASS: clean logs. FAIL: PII/secrets in logs.
5. **MISC-05: Error responses do not leak stack traces in production.** PASS: generic errors. FAIL: stack traces exposed.
6. **MISC-06: HTTP headers strip server version info.** PASS: stripped. FAIL: version exposed.
7. **MISC-07: CORS allows only specific origins.** PASS: specific. FAIL: wildcard.
8. **MISC-08: No debug endpoints enabled in production.** PASS: disabled. FAIL: debug routes accessible.
9. **MISC-09: Deprecation warnings addressed.** PASS: no critical deprecations. FAIL: outdated APIs/libs.
10. **MISC-10: Previous audit findings tracked and remediated.** Read prior audit if exists. PASS: findings addressed. FAIL: regressions found.

---

# WS11: PII (Personal Data Exposure)

Scope: Scan ALL source code, public files, structured data, env examples, Docker compose files, and documentation for exposed personal information. This workstream was added after the March 26, 2026 incident where personal data was found publicly exposed across 4 live websites.

## Files to Read

- src/app/**/layout.tsx (JSON-LD structured data)
- src/app/**/page.tsx (meta tags, JSON-LD)
- public/ai.txt
- public/llms.txt
- public/.well-known/ai-plugin.json
- public/manifest.json
- .env.example (all instances across repo)
- docker-compose*.yml (all compose files)
- next.config.* (allowedDevOrigins)
- **/constants.ts or **/config.ts (hardcoded contact info)
- tests/**/*.test.ts (real data in test fixtures)
- README.md, AGENTS.md, CONFIDENTIAL.md (docs in repo root)

## Checks

1. **PII-01: No personal emails in source code.** Grep for `avi2k3x@gmail.com`, any `@gmail.com`, `@yahoo.com`, `@hotmail.com` addresses in src/, public/, or app/ directories. PASS: none found or only business domain emails. FAIL: personal email addresses in code or public files.
2. **PII-02: No personal phone numbers.** Grep for `052-232-3884`, `054-717-4272`, `+972-54`, `+972-52` with specific numbers. PASS: none found. FAIL: personal phone numbers hardcoded.
3. **PII-03: No founder names in public-facing markup.** Check JSON-LD, meta tags, and structured data for `Avi Kaner`, `Idan Kupfer`, or other real names in `founder`, `author`, or `Person` schema fields. PASS: only company names used. FAIL: personal names in public markup.
4. **PII-04: No Telegram IDs as hardcoded defaults.** Check .env.example and docker-compose files for real Telegram chat IDs (`6659800746`, `170989038`, `-1003821405603`) used as values or fallback defaults. PASS: blank placeholders or `${VAR:?required}`. FAIL: real IDs as defaults.
5. **PII-05: No internal IPs in client-accessible code.** Check next.config.*, source code, and compose files for `100.80.97.14`, internal Tailscale IPs, or other private infrastructure IPs. PASS: none found or only in server-only code. FAIL: internal IPs in client-accessible config.
6. **PII-06: No server paths in committed files.** Grep for `/home/avi/`, `/home/ubuntu/`, or other server filesystem paths in committed code or docs. PASS: none or only in deploy scripts. FAIL: server paths in README, docs, or source.
7. **PII-07: No personal handles in production CTAs.** Check for `@Tokenized2027` or other personal social media handles used as contact CTAs on public pages. PASS: only business handles. FAIL: personal handles on public pages.
8. **PII-08: .env.example uses blank placeholders only.** No real values for secrets, IDs, connection strings, or passwords. PASS: all blank or clearly fake. FAIL: real values committed.
9. **PII-09: Docker compose uses fail-loud for sensitive vars.** Compose files use `${VAR:?required}` not `${VAR:-realvalue}` for Telegram IDs, chat IDs, and secrets. PASS: fail-loud pattern. FAIL: silent fallback to real values.
10. **PII-10: Test fixtures use fake data.** Test files don't contain real names, phone numbers, or email addresses. PASS: fake data (`test@example.com`, `John Doe`). FAIL: real personal data in tests.
11. **PII-11: Public static files clean.** `ai.txt`, `llms.txt`, `ai-plugin.json` contain only business emails and company names. PASS: clean. FAIL: personal data.
12. **PII-12: JSON-LD contactPoint uses business email.** Organization schema `contactPoint.email` uses domain email, not personal. PASS: business email. FAIL: personal email.
