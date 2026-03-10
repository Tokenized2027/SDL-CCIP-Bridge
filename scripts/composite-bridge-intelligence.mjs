/**
 * Composite Bridge Intelligence (Phase 1.5)
 *
 * After all 3 CRE workflows complete, this script:
 * 1. Reads all 3 bridge workflow snapshots
 * 2. Cross-correlates vault health + AI advisor + queue monitor data
 * 3. Optionally calls AI for ecosystem-aware composite analysis
 * 4. Produces a single composite snapshot with unified risk assessment
 *
 * The composite snapshot captures cross-workflow intelligence that no
 * single workflow can see in isolation. For example: high utilization
 * alone might be fine, but high utilization + growing queue + AI advisor
 * recommending parameter change = escalation.
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DATA_DIR = join(__dirname, '..', 'intelligence', 'data');
const OUTPUT_FILE = join(DATA_DIR, 'cre_bridge_composite_snapshot.json');
const AI_ENDPOINT = process.env.AI_ENDPOINT || 'http://localhost:5051/api/cre/analyze-bridge-composite';
const AI_ENABLED = process.env.AI_ENABLED !== 'false';

// ─── Load snapshots ───

function loadSnapshot(filename) {
  const path = join(DATA_DIR, filename);
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf-8'));
  } catch {
    return null;
  }
}

// ─── Cross-correlate ───

function crossCorrelate(vaultHealth, advisor, queueMonitor) {
  const signals = [];
  let worstRisk = 'ok';

  // Extract key metrics
  const utilBps = vaultHealth?.health?.utilizationBps ?? 0;
  const queueDepth = queueMonitor?.queue?.pendingCount ?? 0;
  const coverageRatio = queueMonitor?.health?.liquidityCoverageRatio ?? 1;
  const aiRisk = advisor?.aiAnalysis?.risk ?? advisor?.risk ?? 'ok';
  const aiConfidence = advisor?.aiAnalysis?.confidence ?? 0;
  const sharePrice = vaultHealth?.health?.sharePrice ?? 1;
  const reserveRatio = vaultHealth?.health?.badDebtReserveRatio ?? 0;
  const linkUsd = vaultHealth?.health?.linkUsd ?? 0;
  const tvlUsd = vaultHealth?.health?.tvlUsd ?? 0;

  // Cross-workflow correlations
  if (utilBps >= 7000 && queueDepth > 0) {
    signals.push(`High utilization (${utilBps}bps) with active queue (${queueDepth} pending): LP liquidity crunch risk`);
    worstRisk = 'warning';
  }

  if (utilBps >= 9000 && queueDepth >= 3) {
    signals.push(`Critical utilization (${utilBps}bps) with queue buildup (${queueDepth}): immediate governance attention needed`);
    worstRisk = 'critical';
  }

  if (aiRisk === 'critical' && aiConfidence > 0.7) {
    signals.push(`AI advisor flags critical risk with ${(aiConfidence * 100).toFixed(0)}% confidence`);
    worstRisk = 'critical';
  } else if (aiRisk === 'warning' && aiConfidence > 0.6) {
    signals.push(`AI advisor flags warning with ${(aiConfidence * 100).toFixed(0)}% confidence`);
    if (worstRisk === 'ok') worstRisk = 'warning';
  }

  if (reserveRatio < 0.03 && utilBps > 5000) {
    signals.push(`Low bad debt reserve (${(reserveRatio * 100).toFixed(2)}%) under moderate utilization: settlement loss exposure`);
    if (worstRisk === 'ok') worstRisk = 'warning';
  }

  if (coverageRatio < 0.3 && queueDepth > 0) {
    signals.push(`Queue liquidity coverage at ${(coverageRatio * 100).toFixed(1)}%: processing will stall`);
    worstRisk = 'critical';
  }

  if (sharePrice < 0.99) {
    signals.push(`Share price depreciation: ${sharePrice.toFixed(6)} (LP NAV loss detected)`);
    if (worstRisk === 'ok') worstRisk = 'warning';
  }

  // AI policy adjustment signals
  const policyAdj = advisor?.aiAnalysis?.policyAdjustments;
  if (policyAdj) {
    const currentMaxUtil = vaultHealth?.policy?.maxUtilizationBps ?? 6000;
    if (policyAdj.maxUtilizationBps && policyAdj.maxUtilizationBps !== currentMaxUtil) {
      signals.push(`AI recommends adjusting maxUtilization from ${currentMaxUtil}bps to ${policyAdj.maxUtilizationBps}bps`);
    }
  }

  if (signals.length === 0) {
    signals.push('All bridge systems nominal: vault healthy, queue clear, AI satisfied');
  }

  return {
    compositeRisk: worstRisk,
    signals,
    vaultUtilBps: utilBps,
    queueDepth,
    coverageRatio,
    reserveRatio,
    sharePrice,
    linkUsd,
    tvlUsd,
    aiRisk,
    aiConfidence,
    policyAdjustments: policyAdj || null,
  };
}

// ─── Optional AI composite analysis ───

async function callAIComposite(compositeData) {
  if (!AI_ENABLED) return null;

  try {
    const resp = await fetch(AI_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        workflow: 'bridge-composite',
        data: compositeData,
        requestedAnalysis: ['ecosystem_risk', 'cross_workflow_correlation', 'action_priority'],
      }),
    });

    if (resp.ok) {
      const result = await resp.json();
      console.log(`AI composite analysis: risk=${result.risk}, confidence=${result.confidence}`);
      return result;
    }
    console.log(`AI composite endpoint returned ${resp.status}`);
  } catch (e) {
    console.log(`AI composite failed (non-fatal): ${e.message}`);
  }
  return null;
}

// ─── Main ───

async function main() {
  console.log('=== Composite Bridge Intelligence ===');

  const vaultHealth = loadSnapshot('cre_vault_health_snapshot.json');
  const advisor = loadSnapshot('cre_bridge_advisor_snapshot.json');
  const queueMonitor = loadSnapshot('cre_queue_monitor_snapshot.json');

  const loaded = [
    vaultHealth ? 'vault-health' : null,
    advisor ? 'bridge-advisor' : null,
    queueMonitor ? 'queue-monitor' : null,
  ].filter(Boolean);

  console.log(`Loaded snapshots: ${loaded.join(', ') || 'none'}`);

  if (loaded.length === 0) {
    console.log('No snapshots available. Skipping composite analysis.');
    return;
  }

  // Cross-correlate
  const composite = crossCorrelate(vaultHealth, advisor, queueMonitor);
  console.log(`Composite risk: ${composite.compositeRisk}`);
  composite.signals.forEach((s) => console.log(`  - ${s}`));

  // Optional AI overlay
  const aiComposite = await callAIComposite(composite);
  if (aiComposite) {
    composite.aiCompositeAnalysis = aiComposite;
    if (aiComposite.risk === 'critical' && composite.compositeRisk !== 'critical') {
      console.log(`AI escalated composite risk to critical (was ${composite.compositeRisk})`);
      composite.compositeRisk = 'critical';
    }
  }

  // Confidence: based on how many workflows contributed
  composite.confidence = loaded.length / 3;

  // Write snapshot
  const snapshot = {
    generated_at_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
    source: 'composite_intelligence',
    workflowsContributed: loaded,
    ...composite,
  };

  mkdirSync(dirname(OUTPUT_FILE), { recursive: true });
  writeFileSync(OUTPUT_FILE, JSON.stringify(snapshot, null, 2));
  console.log(`Wrote composite snapshot to ${OUTPUT_FILE}`);
}

main().catch((e) => {
  console.error('Fatal:', e);
  process.exit(1);
});
