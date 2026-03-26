# PentAGI Integration (Dynamic Application Security Testing)

Optional DAST layer activated with `--pentest` flag. Runs active penetration testing against a live target (staging) using PentAGI's autonomous AI agent framework.

## What PentAGI Provides

PentAGI (https://github.com/vxcontrol/pentagi) is a self-hosted autonomous pentest system with:
- 20+ security tools: nmap, metasploit, sqlmap, nikto, etc.
- Multi-agent architecture: Researcher, Developer, Executor, Adviser
- REST + GraphQL APIs for programmatic access
- Knowledge persistence via PostgreSQL + pgvector + Neo4j
- Report generation

## Prerequisites

PentAGI must be running as a Docker Compose stack. It is NOT installed by default.

### Installation (one-time)

```bash
git clone https://github.com/vxcontrol/pentagi.git ~/pentagi
cd ~/pentagi
cp .env.example .env
# Edit .env: set ANTHROPIC_API_KEY, OPENAI_API_KEY, database passwords
docker compose up -d
```

### Verify Running

```bash
curl -s http://localhost:8080/api/health
```

If this returns a healthy response, PentAGI is available.

## Integration Workflow

### Step 1: Check Availability

```bash
PENTAGI_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/api/health 2>/dev/null)
```

- If `200`: proceed with DAST
- If anything else: skip with message "Dynamic testing skipped: PentAGI not running"

### Step 2: Create Pentest Task

Feed static analysis findings as context. Use the REST API to create a new task:

```bash
curl -X POST http://localhost:8080/api/v1/tasks \
  -H "Authorization: Bearer ${PENTAGI_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "objective": "Penetration test of Ottomatt staging environment",
    "target": "staging.ottomatt.co.il",
    "context": "<static analysis findings summary>",
    "scope": [
      "staging.ottomatt.co.il",
      "staging.ottomatt.co.il:443"
    ],
    "restrictions": [
      "Do not perform denial-of-service attacks",
      "Do not modify or delete data",
      "Do not attempt to access production systems",
      "Stay within scope: staging.ottomatt.co.il only"
    ]
  }'
```

### Step 3: Monitor Progress

Poll the task status via GraphQL:

```graphql
query {
  task(id: "<task_id>") {
    status
    progress
    findings {
      title
      severity
      description
      evidence
      recommendation
    }
  }
}
```

### Step 4: Collect Results

When task completes, retrieve findings:

```bash
curl http://localhost:8080/api/v1/tasks/<task_id>/findings \
  -H "Authorization: Bearer ${PENTAGI_TOKEN}"
```

### Step 5: Merge with Static Analysis

For each PentAGI finding:
1. Check if a matching static analysis finding exists (same endpoint, same vulnerability class)
2. If match: upgrade to "CONFIRMED" (exploitable in practice, not just theoretical)
3. If no match: add as "DAST-XX" finding with evidence from PentAGI
4. PentAGI findings that confirm static analysis findings get severity bump

### Finding Tags

| Tag | Meaning |
|-----|---------|
| CONFIRMED | Static analysis finding verified by dynamic testing |
| THEORETICAL | Static analysis finding, not dynamically tested or test inconclusive |
| DAST-ONLY | Found by dynamic testing only, no corresponding static finding |

## Safety Rules

1. **NEVER target production** (ottomatt-prod / 51.84.176.104)
2. **ALWAYS target staging** (staging.ottomatt.co.il / 51.16.113.229)
3. Set explicit scope restrictions in PentAGI task config
4. Disable destructive attacks (DoS, data modification)
5. Time-box the pentest to 30 minutes max
6. Review PentAGI's planned actions before execution if Adviser agent flags concerns

## When PentAGI Is Not Available

The security audit works perfectly without PentAGI. The 10 static analysis workstreams provide comprehensive coverage. PentAGI adds:
- Confirmation of exploitability (theoretical -> confirmed)
- Network-level findings not visible in code (misconfigurations, exposed services)
- Runtime behavior testing (actual response codes, timing, error messages)

If PentAGI is not running, the audit simply notes: "Dynamic testing was not performed. All findings are based on static code analysis."
