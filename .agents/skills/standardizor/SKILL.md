---
name: standardizor
description: Use when the user wants a brutal repo drift audit or needs to reconcile docs, code, env vars, API keys, endpoints, providers, CI or deploy commands, generated artifacts, or capability claims. This skill inventories the repo, chooses the right source of truth, and reports precise contradictions with fixes.
---

# Standardizor

Use this when:

1. docs feel stale, contradictory, or suspiciously optimistic
2. chain, RPC, Chainlink, or settlement config drifted
3. env vars, endpoints, scripts, or workflows no longer match contract reality
4. CI, forge commands, or operator workflow docs disagree
5. the user asks what is actually true in this repo today

## Repo-First Read Order

1. `AGENTS.md`
2. `CLAUDE.md`
3. `README.md`
4. `CHAINLINK.md`
5. `docs/workflows/paperclip-operating-model.md`
6. then the exact contract, test, script, workflow, or platform files involved

If a documented source of truth is missing, treat that as drift. Do not invent one.

## Audit Workflow

1. Build a source-of-truth map for contract behavior, operator workflow, env vars, chain config, and release or verification flow.
2. Inventory the real repo surfaces: `foundry.toml`, manifests, env usage, scripts, workflows, platform tooling, tests, docs, and settlement or Chainlink touchpoints.
3. Cross-check docs vs code, manifests vs lockfiles, env docs vs runtime usage, scripts vs workflow docs, tests vs claimed safety properties, and operator docs vs real commands.
4. Search aggressively for drift seeds such as `RPC`, `CHAINLINK`, `CCIP`, `SECRET`, `TOKEN`, `KEY`, `BASE_URL`, `ENDPOINT`, `deprecated`, `legacy`, `TODO`, and `FIXME`.
5. Treat any committed real secret, likely live credential, or dangerous production mismatch as `CRITICAL`.
6. If version support, SDK deprecation, or endpoint sunset needs external verification, use only official docs or changelogs.
7. Recommend the smallest real fix that restores one trusted story for the repo.

## Required Output

Report findings first, no fluff.

Use this format for each finding:

`SEVERITY | category | path:line`
Source of truth: `...`
Observed drift: `...`
Impact: `...`
Fix: `...`
Evidence: `...`

End with:

`DRIFT SUMMARY`
- Verified findings: X
- Critical: X
- High: X
- Medium: X
- Low: X
- Highest leverage fix: `...`

## Guardrails

- Never call something drift unless both sides were checked.
- Never leave `update docs` as a vague fix. Name the file.
- Do not trust README text over the contracts, tests, or live workflow scripts.
- Do not collapse planned, partial, and shipped into one bucket.
- If you find an incomplete rename or provider migration, trace every surviving old name.
- If the repo has no clean source-of-truth doc for a category, say that explicitly.
