/**
 * Record Bridge Proofs: reads CRE workflow snapshots and writes keccak256
 * proof hashes to SentinelRegistry on Sepolia.
 *
 * Deduplication: tracks generated_at_utc per workflow, only writes if snapshot
 * is newer than last write.
 */

import { createWalletClient, createPublicClient, http, keccak256, encodeAbiParameters, parseAbiParameters, encodeFunctionData } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia } from 'viem/chains';
import { readFileSync, writeFileSync, renameSync, existsSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const DATA_DIR = join(__dirname, '..', 'intelligence', 'data');
const STATE_FILE = join(__dirname, '.last-bridge-write-state.json');

const REGISTRY_ADDRESS = process.env.REGISTRY_ADDRESS || '0x35EFB15A46Fa63262dA1c4D8DE02502Dd8b6E3a5';
const RPC_URL = process.env.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com';
const PRIVATE_KEY = process.env.PRIVATE_KEY;

if (!PRIVATE_KEY) {
  console.error('PRIVATE_KEY env var required');
  process.exit(1);
}

const REGISTRY_ABI = [
  {
    name: 'recordHealth',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'snapshotHash', type: 'bytes32' },
      { name: 'riskLevel', type: 'string' },
    ],
    outputs: [],
  },
  {
    name: 'recorded',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: '', type: 'bytes32' }],
    outputs: [{ name: '', type: 'bool' }],
  },
];

// ─── Workflow definitions ───

const WORKFLOWS = [
  {
    key: 'vault-health',
    file: 'cre_vault_health_snapshot.json',
    extractRisk: (d) => d.risk || 'ok',
    hashFields: (d) => {
      const ts = BigInt(Math.floor(new Date(d.generated_at_utc || d.timestamp).getTime() / 1000));
      const risk = d.risk || 'ok';
      const utilBps = BigInt(d.health?.utilizationBps ?? 0);
      // Use raw string values directly (no parseFloat) to match workflow hash encoding
      const totalAssets = BigInt(d.buckets?.totalAssets ?? '0');
      const freeLiq = BigInt(d.buckets?.freeLiquidityAssets ?? '0');
      const queueDepth = BigInt(d.health?.queueDepth ?? 0);
      const reserveRatio = BigInt(Math.round((d.health?.badDebtReserveRatio ?? 0) * 1e6));
      const sharePrice = BigInt(Math.round((d.health?.sharePrice ?? 1) * 1e6));
      return encodeAbiParameters(
        parseAbiParameters('uint256 ts, string wf, string risk, uint256 utilBps, uint256 totalAssets, uint256 freeLiq, uint256 queueDepth, uint256 reserveRatio, uint256 sharePrice'),
        [ts, 'vault-health', risk, utilBps, totalAssets, freeLiq, queueDepth, reserveRatio, sharePrice],
      );
    },
  },
  {
    key: 'bridge-advisor',
    file: 'cre_bridge_advisor_snapshot.json',
    extractRisk: (d) => d.risk || 'ok',
    hashFields: (d) => {
      const ts = BigInt(Math.floor(new Date(d.generated_at_utc || d.timestamp).getTime() / 1000));
      const risk = d.risk || 'ok';
      const utilBps = BigInt(d.vaultState?.utilizationBps ?? 0);
      const queueDepth = BigInt(d.vaultState?.queueDepth ?? 0);
      const confidence = BigInt(Math.round((d.aiAnalysis?.confidence ?? 0) * 100));
      return encodeAbiParameters(
        parseAbiParameters('uint256 ts, string wf, string risk, uint256 utilBps, uint256 queueDepth, uint256 confidence'),
        [ts, 'bridge-advisor', risk, utilBps, queueDepth, confidence],
      );
    },
  },
  {
    key: 'queue-monitor',
    file: 'cre_queue_monitor_snapshot.json',
    extractRisk: (d) => d.risk || 'ok',
    hashFields: (d) => {
      const ts = BigInt(Math.floor(new Date(d.generated_at_utc || d.timestamp).getTime() / 1000));
      const risk = d.risk || 'ok';
      const queueDepth = BigInt(d.queue?.pendingCount ?? 0);
      const coverageRatio = BigInt(Math.round((d.health?.liquidityCoverageRatio ?? 1) * 1e6));
      const utilBps = BigInt(d.health?.utilizationBps ?? 0);
      return encodeAbiParameters(
        parseAbiParameters('uint256 ts, string wf, string risk, uint256 queueDepth, uint256 coverageRatio, uint256 utilBps'),
        [ts, 'queue-monitor', risk, queueDepth, coverageRatio, utilBps],
      );
    },
  },
  {
    key: 'bridge-composite',
    file: 'cre_bridge_composite_snapshot.json',
    extractRisk: (d) => d.compositeRisk || 'ok',
    hashFields: (d) => {
      const ts = BigInt(Math.floor(new Date(d.generated_at_utc || d.timestamp).getTime() / 1000));
      const risk = d.compositeRisk || 'ok';
      const utilBps = BigInt(d.vaultUtilBps ?? 0);
      const queueDepth = BigInt(d.queueDepth ?? 0);
      const confidence = BigInt(Math.round((d.confidence ?? 0) * 100));
      return encodeAbiParameters(
        parseAbiParameters('uint256 ts, string wf, string risk, uint256 utilBps, uint256 queueDepth, uint256 confidence'),
        [ts, 'bridge-composite', risk, utilBps, queueDepth, confidence],
      );
    },
  },
];

// ─── Main ───

async function main() {
  const account = privateKeyToAccount(PRIVATE_KEY);
  const publicClient = createPublicClient({ chain: sepolia, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account, chain: sepolia, transport: http(RPC_URL) });

  // Load last-write state
  let state = {};
  if (existsSync(STATE_FILE)) {
    try {
      state = JSON.parse(readFileSync(STATE_FILE, 'utf-8'));
    } catch { /* fresh state */ }
  }

  let written = 0;
  let skipped = 0;
  let failed = 0;

  for (const wf of WORKFLOWS) {
    const filePath = join(DATA_DIR, wf.file);
    if (!existsSync(filePath)) {
      console.log(`[${wf.key}] Snapshot not found: ${wf.file} (skipped)`);
      skipped++;
      continue;
    }

    let data;
    try {
      data = JSON.parse(readFileSync(filePath, 'utf-8'));
    } catch (e) {
      console.log(`[${wf.key}] Failed to parse: ${e.message} (skipped)`);
      skipped++;
      continue;
    }

    // Dedup check
    const generatedAt = data.generated_at_utc || data.timestamp;
    if (state[wf.key] === generatedAt) {
      console.log(`[${wf.key}] Already written for ${generatedAt} (skipped)`);
      skipped++;
      continue;
    }

    // Compute hash
    const encoded = wf.hashFields(data);
    const hash = keccak256(encoded);
    const risk = wf.extractRisk(data);

    // Check if already on-chain
    try {
      const alreadyRecorded = await publicClient.readContract({
        address: REGISTRY_ADDRESS,
        abi: REGISTRY_ABI,
        functionName: 'recorded',
        args: [hash],
      });
      if (alreadyRecorded) {
        console.log(`[${wf.key}] Hash already on-chain (skipped)`);
        state[wf.key] = generatedAt;
        skipped++;
        continue;
      }
    } catch (e) {
      console.log(`[${wf.key}] On-chain check failed: ${e.message}`);
    }

    // Write to registry
    try {
      const txHash = await walletClient.writeContract({
        address: REGISTRY_ADDRESS,
        abi: REGISTRY_ABI,
        functionName: 'recordHealth',
        args: [hash, `${wf.key}:${risk}`],
      });
      console.log(`[${wf.key}] Proof written: ${wf.key}:${risk} tx=${txHash}`);
      state[wf.key] = generatedAt;
      written++;
    } catch (e) {
      console.log(`[${wf.key}] Write failed: ${e.message}`);
      failed++;
    }
  }

  // Save state atomically (write to temp, then rename)
  const tmpFile = STATE_FILE + '.tmp';
  writeFileSync(tmpFile, JSON.stringify(state, null, 2));
  renameSync(tmpFile, STATE_FILE);
  console.log(`\nSummary: ${written} written, ${skipped} skipped, ${failed} failed`);
}

main().catch((e) => {
  console.error('Fatal:', e);
  process.exit(1);
});
